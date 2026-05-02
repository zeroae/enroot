# ZFS storage backend

This document describes an optional ZFS-aware mode for the enroot container store. **All six plans (A–F) are implemented; Plan G adds an opt-in per-layer clone chain on top of F.** When `ENROOT_STORAGE_BACKEND=zfs`: `enroot create`, `enroot remove`, ephemeral `enroot start <image>`, and `enroot load docker://...` all use ZFS datasets, with a shared template cache that survives `enroot remove` (warm) for `ENROOT_TEMPLATE_WARM_SECONDS` and gets pressure-evicted LRU once the templates dataset crosses `ENROOT_TEMPLATE_PRESSURE_THRESHOLD` of its quota. `enroot create` accepts both `.sqsh` and `.zfs` (zfs send stream) inputs; `enroot export --format=zfs` produces the latter. The `zfs://[USER@]HOST/NAME` URI scheme transports containers between enroot hosts over SSH (`enroot load zfs://...` to pull, `enroot export NAME zfs://...` to push). The default storage backend (plain directories under `ENROOT_DATA_PATH`) is unchanged and remains the only option on hosts without ZFS.

## Motivation

Today, `enroot create foo.sqsh -n NAME` does a fresh `unsquashfs` of the entire image into `${ENROOT_DATA_PATH}/NAME`. Two creates from the same image produce two independent, fully-extracted copies on disk; nothing is shared. On HPC nodes where many users run containers built from a small set of common base images (CUDA, PyTorch, Ubuntu LTS), this wastes both extraction time and disk space.

The ZFS backend is an *alternative storage driver*, in the same spirit as Docker's pluggable storage drivers (`overlay2`, `zfs`, `btrfs`, …). When configured, it substitutes ZFS-native operations for three of enroot's storage code paths — `create`, ephemeral `start <image>`, and `load docker://` — replacing extraction-per-create with extract-once-then-clone, and replacing overlay-on-squashfuse with throwaway clones. Hosts without ZFS, and the default `dir` backend on ZFS hosts, are untouched.

## Configuration knobs

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_STORAGE_BACKEND` | `dir` | `dir` = today's behavior. `zfs` = use ZFS datasets for the container store. |
| `ENROOT_TEMPLATE_WARM_SECONDS` | `604800` (7 days) | How long a template with no clones remains evictable only under pressure. `0` = evict immediately when refcount reaches zero (refcount-only). `inf` = never auto-evict. |
| `ENROOT_TEMPLATE_PRESSURE_THRESHOLD` | `0.80` | Templates dataset quota fraction above which routine `create`s start evicting warm templates. Soft signal; the ZFS quota is the hard wall. |
| `ENROOT_ZFS_LAYER_CHAIN` | unset | When `y` AND backend is `zfs`, populate the Docker template cache via a per-layer `zfs clone` chain under `<store>/.layers/<digest>` instead of a single merged extract. Cross-image base layers are physically shared on disk (a debian-bookworm base used by both `python:slim` and `node:slim` is stored once). Default off — leaves Plan F's single-merge path unchanged. |

When `ENROOT_STORAGE_BACKEND=zfs`, `ENROOT_DATA_PATH` must be the mountpoint of a ZFS dataset that the unprivileged user has been granted permission on (see [Admin setup](#admin-setup)).

## Store layout

```
${pool}/${dataset}/templates/<sha256>            # one per distinct image content
${pool}/${dataset}/templates/<sha256>@pristine   # snapshot taken after extraction
${pool}/${dataset}/<user>/<container_name>       # clones of @pristine, the user's containers
```

When `ENROOT_ZFS_LAYER_CHAIN=y`, an additional `.layers/` namespace appears under the same store; templates become clones of the chain leaf instead of being filled by a single merged extract:

```
${pool}/${dataset}/.layers/<layer-digest>            # one per distinct registry layer
${pool}/${dataset}/.layers/<layer-digest>@done       # snapshot taken after layer apply
${pool}/${dataset}/.templates/<image-config-sha>     # zfs clone of the chain leaf @done
${pool}/${dataset}/.templates/<image-config-sha>@pristine
```

Each layer dataset is `zfs clone`d from the previous layer's `@done`, so two images sharing a base layer (e.g. `python:3.12-slim` and `node:20-slim`, both built on `debian:bookworm-slim`) physically share the base bytes. Layer datasets are immutable origins; ZFS refuses to destroy a layer while any descendant clone exists, so layer GC is automatic once all referencing templates are evicted.

Mountpoints follow the dataset hierarchy under `ENROOT_DATA_PATH`. Templates are not user-visible — `enroot list` only enumerates `<user>/<container_name>` clones. Templates have `readonly=on`; clones inherit the property override on `start -w`.

The `templates` dataset is shared across all users on the host. Its quota and properties are admin-controlled (see below).

## Container lifecycle

### `enroot create` from `.sqsh`

Input is a portable squashfs image, identical to today.

1. Compute `sha256` of `foo.sqsh`.
2. **Cache hit:** `templates/<sha256>@pristine` exists — skip to step 5.
3. **Cache miss, win the extractor race:** atomically `zfs create templates/<sha256>.tmp`. The dataset's existence is the lock; whoever wins this is the extractor.
4. **Extract:** `unsquashfs` into `templates/<sha256>.tmp`, then `zfs rename .tmp <sha256>`, `zfs snapshot @pristine`, `zfs set readonly=on`.
5. **Cache miss, lost the race:** another process is extracting; wait for `@pristine` to appear (bounded poll). If the orphan `.tmp` is past timeout with no live process, destroy and retry from step 2.
6. Update `enroot:last_used=<now>` on the template.
7. `zfs clone templates/<sha256>@pristine <user>/<NAME>`.

End state: the user's container is a fresh, writable dataset clone of an immutable shared template.

### `enroot create` from `.zfs`

A `.zfs` file is a `zfs send` stream — not a mountable filesystem, not portable across non-ZFS hosts. The flow mirrors `.sqsh` but replaces extraction with receive:

| Step | `.sqsh` path | `.zfs` path |
| ------ | ------ | ------ |
| Cache key | `sha256` of file | `sha256` of file |
| Materialize template | `unsquashfs` into dataset | `zfs recv` into dataset |
| Snapshot | `zfs snapshot @pristine` | snapshot in stream is preserved |
| Spawn container | `zfs clone @pristine` | `zfs clone @pristine` |

`enroot create foo.zfs` on a non-ZFS host (`ENROOT_STORAGE_BACKEND≠zfs` or no ZFS pool) is a hard error: `.zfs` images require the ZFS backend. `.sqsh` images keep working everywhere.

The dispatcher picks the path by file extension. There is no magic-byte sniffing; `.sqsh` is always squashfs and `.zfs` is always a stream.

## Pointer-format import (default on ZFS backend)

When `ENROOT_STORAGE_BACKEND=zfs`, `enroot import docker://<ref>` writes a
small (< 1 KiB) **pointer file** instead of a real squashfs image. The pointer
carries the docker manifest digest and the `image-config-sha256` (the same
stable cache key used by direct `enroot create docker://<ref>`). `enroot
create` reads the pointer and clones the cached template — `O(zfs clone)`,
subseconds — instead of running `unsquashfs`. Repeat imports of the same
image hit the existing template cache, even though each `enroot import`
otherwise produces a non-deterministic squashfs (timestamps and per-build
metadata leak through `mksquashfs`).

Pointer files are recognizable by their first line:

```
enroot-zfs-image:v1
image-config-sha256=<64-hex>
manifest-digest=sha256:<64-hex>
arch=arm64
uri=docker://registry-1.docker.io/library/ubuntu:24.04
imported=2026-04-29T18:23:11Z
```

Pyxis treats the file as opaque (writes to a per-uid runtime dir, deletes it
after `enroot create`), so the format change is invisible to pyxis.

### Daemon URIs (`dockerd://`, `podman://`)

`enroot import dockerd://<image>` and `enroot import podman://<image>` participate in the same pointer cache. The cache key is the daemon-reported image ID (`${engine} inspect --format='{{.Id}}'`), which matches the `image-config-sha256` of a `docker://`-pulled equivalent for registry-pulled images — so a daemon import of `ubuntu:24.04` shares the cache with a registry import of the same reference for free.

Daemon-local images don't have a registry manifest digest, so the pointer file's `manifest-digest=` line is omitted. The `enroot:manifest-digest` user property is also unset on the corresponding template. All other fields (`enroot:uri`, `enroot:arch`, `enroot:imported`) are populated normally; the inspection one-liner above shows daemon-sourced templates with `enroot:uri=dockerd://...`.

### Opting out

Set `ENROOT_ZFS_IMPORT_FORMAT=squashfs` in the environment or the config
file to force the legacy behavior (real `.sqsh`). The same effect is reachable
per-invocation via `enroot import --format=squashfs docker://<ref>`. Use this
when you need a portable squashfs artifact (e.g. to copy across nodes that
don't share a ZFS pool).

### Eviction recovery

Templates are reaped by the existing warm/cold sweep on each `enroot create`
(see `ENROOT_TEMPLATE_WARM_SECONDS` and `ENROOT_TEMPLATE_PRESSURE_THRESHOLD`).
If the pointer's referenced template was evicted between import and create,
`enroot create` re-pulls from the pointer's `uri` and validates that the
freshly-resolved `image-config-sha256` still matches the pointer's claim. If
the upstream tag has been republished (different config sha), `enroot create`
errors out with a "delete and re-import" message — silently substituting a
different image would defeat the whole point of content-addressing the cache.

### Cross-node portability

A pointer file references a template that lives in the importing node's ZFS
pool. Pointers are not portable to other nodes (the referenced template will
not exist there). For multi-node workflows:

- Per-node pointer imports — let each node import its own pointer; the cache
  and the work both stay local. This is what pyxis already does.
- `--format=squashfs` — produce a real squashfs, copy it.
- The existing `zfs://<host>/<name>` send-stream transport — push a populated
  template to a peer over SSH.

### `enroot remove`

Destroys the user's clone:

```
zfs destroy ${pool}/${dataset}/<user>/<NAME>
```

This is fast, atomic, and naturally sidesteps the restricted-permission-directory failure mode of `rm -rf`.

The template is **not** destroyed at remove time. It transitions to a warm state and waits for the eviction sweep on the next `create` (see below). This is a deliberate change from refcount-on-remove: `enroot remove` returns faster, but disk does not shrink immediately.

### `enroot export NAME`

Default output is `.sqsh`, produced by running `mksquashfs` against the live clone — identical to today's `enroot export` output, portable to any host.

`enroot export NAME --format=zfs` produces `NAME.zfs` via `zfs send <user>/<NAME>@pristine > NAME.zfs`. Requires the source host to be running the ZFS backend.

### `enroot bundle`

Always produces a `.sqsh`-backed `.run`, regardless of source backend. Bundles must run on hosts without ZFS, so the bundle pipeline stays squashfs-only. If the source container is on ZFS, bundle runs `mksquashfs` against the clone first.

## Image transport

Three transports for the same logical content:

| Transport | When to use | Portable? |
| ------ | ------ | ------ |
| `.sqsh` file | Default. Distribute to any audience. | Yes — any Linux host. |
| `.zfs` file | ZFS-to-ZFS transfer via shared filesystem, sneakernet, S3. | No — receiver must run the ZFS backend. |
| `zfs://host/NAME` URI | ZFS-to-ZFS transfer over SSH. | No — both hosts must run enroot with the ZFS backend. |

### `zfs://` URI

```
enroot import zfs://host/ubuntu_2410          # disallowed; use load
enroot load   zfs://host/ubuntu_2410 -n ub    # fetch + create in one step
enroot export NAME zfs://host                 # push to remote
enroot export NAME zfs://host/NAME2           # push and rename
```

Wire is `ssh host enroot ...`:

- Pull: `ssh host enroot export --format=zfs NAME | zfs recv ...`
- Push: `zfs send <user>/<NAME>@pristine | ssh host enroot import --zfs-recv -n NAME`

The remote's pool name and store path never leak — the URI names a *container on a remote enroot host*, and the remote enroot resolves the local layout itself.

`enroot import zfs://host/NAME` is disallowed because the scheme has no portable file artifact to produce. Use `enroot load zfs://host/NAME` (fetch + create in one step), or `zfs://` flows directly into the template cache.

`zfs://` does not silently fall back to squashfs. If the remote does not understand `--format=zfs`, the operation fails loudly.

Incremental sends (`zfs send -i`) are out of scope for v1. All `zfs://` and `.zfs` transports are full streams.

## Template cache and eviction

Templates are shared and refcount-tracked indirectly via ZFS clone relationships (`zfs list -H -t filesystem -o origin` enumerates clones of a snapshot). Each template has a single user property:

```
enroot:last_used=<unix_ts>     # updated on every clone (extract or reuse)
```

### Lifecycle states

| State | Definition | Evictable? |
| ------ | ------ | ------ |
| Live | At least one clone exists. | No. |
| Warm | No clones, `now - last_used < ENROOT_TEMPLATE_WARM_SECONDS`. | Only under disk pressure. |
| Cold | No clones, `now - last_used >= ENROOT_TEMPLATE_WARM_SECONDS`. | Yes, routinely. |

Live → Warm on `enroot remove` of the last clone. Warm → Live on `enroot create` reusing the template. Warm → Cold by passage of time.

### Eviction triggers

There is no `enroot gc` command and no daemon. All eviction happens implicitly on `enroot create`, in three modes:

- **Routine sweep:** every `create` reaps all cold templates before extracting/receiving. Cheap because templates are few.
- **Pressure sweep:** if the templates dataset has a quota set and `used/quota >= ENROOT_TEMPLATE_PRESSURE_THRESHOLD`, also reap warm templates LRU until back under the threshold.
- **ENOSPC retry:** if `zfs recv` or `unsquashfs` fails for space (race, or quota too tight), reap any remaining warm templates and retry once. Hard fail on the second ENOSPC.

### Algorithm

```
on enroot create:
    candidates = templates with no clones, sorted by enroot:last_used ASC
    pressure = (quota set on templates and used/quota >= PRESSURE_THRESHOLD)

    for t in candidates:
        is_warm = (now - t.last_used) < WARM_SECONDS
        if is_warm and not pressure:
            continue
        zfs destroy t
        if pressure and used/quota < PRESSURE_THRESHOLD:
            break

    extract/recv into templates/<sha>.tmp → rename → snapshot
    zfs set enroot:last_used=<now> templates/<sha>
    zfs clone templates/<sha>@pristine <user>/<NAME>
```

### Race handling

A concurrent eviction can destroy a template's `@pristine` snapshot just as another `create` tries to clone from it. ZFS will fail one operation atomically. The handler is uniform across all such races — crashed extractors leaving orphan `.tmp` datasets, evicted-mid-clone, and never-snapshotted templates all collapse into the same recovery: fall through to the cache-miss path and re-extract.

The pressure threshold is a soft signal, not a barrier. Two concurrent `create`s seeing "78% used" can both extract and overshoot — the ZFS quota refuses one with ENOSPC and the retry path catches it. The threshold prevents the common case; the quota is the hard wall.

### Inspecting cached templates

Each template dataset carries ZFS user properties recording when it was imported and (for docker-sourced templates) where it came from:

| Property | Set on | Meaning |
|---|---|---|
| `enroot:imported` | every template | RFC3339 UTC timestamp of install |
| `enroot:last_used` | every template, refreshed on each clone | epoch seconds, drives the warm/cold sweep |
| `enroot:uri` | docker-sourced templates | the `docker://...` URI it was pulled from |
| `enroot:manifest-digest` | docker-sourced templates | registry manifest digest at import time |
| `enroot:arch` | docker-sourced templates | debian arch (`arm64`, `amd64`, `ppc64le`) |

A one-liner to see what's cached:

```sh
zfs list -o name,enroot:uri,enroot:imported,enroot:last_used,used \
         -r -d 1 ${POOL}/.templates
```

Properties are replicated by `zfs send -p`, so `enroot:uri` and friends survive the existing `zfs://<host>/<name>` SSH transport — a template pulled to one node carries its provenance to its peers.

Idle templates are unmounted (zero mountpoints under `${ENROOT_DATA_PATH}/.templates`); only active container clones appear in `mount(8)` output. The dataset and its `@pristine` snapshot remain — `zfs clone` does not require the source to be mounted.

## Admin setup

A site enabling the ZFS backend should:

1. **Create a parent dataset** with enroot-friendly properties:

   ```sh
   zpool create tank ...                            # if not already present
   zfs create -o compression=zstd \
              -o atime=off \
              -o xattr=sa \
              -o acltype=posixacl \
              -o mountpoint=/var/lib/enroot \
              tank/enroot
   zfs create tank/enroot/templates
   ```

2. **Set a quota on the templates dataset** to bound disk usage. Sizing rule of thumb: 2–3× the largest single image expected on the host.

   ```sh
   zfs set quota=200G tank/enroot/templates
   ```

3. **Delegate ZFS permissions** to unprivileged users so they can create, clone, and destroy datasets in their own namespace, and receive into the templates cache:

   ```sh
   zfs allow user create,mount,clone,destroy,snapshot,rename,canmount,userprop tank/enroot
   zfs allow user receive tank/enroot/templates
   ```

   `zfs receive` from `.zfs` files and `zfs://` requires this delegation. Without it, the ZFS backend operates only on already-received templates. The `canmount` permission is needed for `zfs clone -o canmount=noauto` (the portable equivalent of `zfs clone -u`, which is OpenZFS 2.3+ only). The `userprop` permission is needed for `enroot:last_used` (the warm/cold lifecycle's per-template timestamp); without it, sweep behavior degrades but `create` / `remove` still work.

   **Linux mount(2) bypass via `enroot-zfs-mount`:** ZFS delegation governs
   ZFS's *internal* logic, but on Linux the kernel `mount(2)` syscall still
   requires `CAP_SYS_ADMIN`. The `enroot+caps` package installs
   `enroot-zfs-mount` with `cap_sys_admin+pe`; the helper validates that the
   caller-supplied dataset is under the parent dataset of `ENROOT_DATA_PATH`
   (read from `/etc/enroot/enroot.conf`, NOT from user-controlled config),
   that its `mountpoint` property is under `ENROOT_DATA_PATH`, and that it
   isn't already mounted, before performing `mount(2)` / `umount2(2)`. With
   `+caps` installed, all unprivileged ZFS-backed flows (`enroot create`,
   `enroot load`, `enroot start <image>`, `enroot remove`) work end-to-end —
   including from inside `slurmstepd` post-privilege-drop, which is what
   pyxis needs.

   Without `+caps`, unprivileged callers cannot mount ZFS datasets and must
   run `enroot create` and friends as root (e.g., via sudo or a
   privilege-elevated systemd unit). The `dir` backend is unaffected.

   **Linux user-namespace caveat:** `zfs list` cannot enumerate datasets from inside a Linux user namespace — even when their mount entries are visible — so any ZFS work must happen *before* `enroot-nsenter --user`. For ephemeral `enroot start <image>` (Plan E), the ephemeral clone is created in `runtime::start` outside the namespace; cleanup is handled by a small "zfs-eph-shim" subshell that mirrors the existing `runtime::_mount_rootfs_shim` pattern — forked into its own process group, parked with `SIGSTOP`, and triggered to `zfs destroy` via the kernel's orphaned-process-group `SIGHUP` rule when the container's exec chain exits. The original `exec enroot-nsenter ...` chain is preserved, so PID semantics, signal forwarding, and `enroot exec PID` all work identically to the `dir` backend.

4. **Configure `ENROOT_STORAGE_BACKEND=zfs`** in `enroot.conf` (or per-user). Set `ENROOT_DATA_PATH` to the mountpoint of `tank/enroot` (or per-user subdataset).

5. **For `zfs://` transport**, ensure passwordless SSH between hosts; standard `ssh_config` Host blocks (port, identity, jump hosts) are honored.

6. **For Docker layer stacking on ZFS** (`enroot load docker://...`), no extra setup beyond the delegations above. The ZFS backend obviates the `ENROOT_NATIVE_OVERLAYFS=y` requirement that the `dir` backend imposes for `enroot load`.

## Where the ZFS backend is used

When `ENROOT_STORAGE_BACKEND=zfs`, ZFS substitutes for the existing storage code paths in three places. The overlayfs and `fuse-overlayfs` paths are not removed — they continue to serve the `dir` backend and any host without ZFS.

| Subsystem | `dir` backend | `zfs` backend |
| ------ | ------ | ------ |
| `enroot create foo.sqsh` | `unsquashfs` into `<store>/<NAME>` | Extract once into `templates/<sha>`, `zfs clone templates/<sha>@pristine <user>/<NAME>`. |
| `enroot start foo.sqsh` (ephemeral; no prior `create`) | `squashfuse` lower layer + overlay upper layer, with kernel `overlay` or `fuse-overlayfs` selected by `ENROOT_NATIVE_OVERLAYFS`. | Ensure template, `zfs clone @pristine` to a unique ephemeral name, `zfs destroy` on exit. |
| `enroot load docker://` (fetch + create in one step) | Layer-stack via `enroot-mksquashovlfs` overlay; requires `ENROOT_NATIVE_OVERLAYFS=y`. | `docker::_prepare_layers` produces extracted, whiteout-converted layer directories `0/`, `1/`, …, `N/` exactly as on the `dir` backend. The merge step reuses the same `enroot-nsenter --user --remap-root` + `mount -t overlay lowerdir=0:1:…:N` pipeline, but the tar-pipe is redirected from a regular directory into the mountpoint of a freshly-created template clone (keyed by image config sha). Cache hits skip the merge entirely. `ENROOT_NATIVE_OVERLAYFS=y` is **not** required; ZFS replaces the precondition. |

`ENROOT_NATIVE_OVERLAYFS` keeps its current meaning when the backend is `dir`. When the backend is `zfs`, the knob is irrelevant for the three substituted paths above (overlay is not used), but it continues to control overlay choice for any code path that does not yet have a ZFS substitution.

The `ENROOT_NATIVE_OVERLAYFS=y` precondition for `enroot load docker://` is **not required** when the ZFS backend is active — ZFS layer-stacking does not depend on kernel overlayfs.

## Behavior change vs. today

When `ENROOT_STORAGE_BACKEND=zfs`:

- **`enroot remove`** no longer reclaims template storage immediately. Reclamation happens on the next `create` (cold sweep) or whenever the warm period expires under pressure. Sites that need eager reclamation should set `ENROOT_TEMPLATE_WARM_SECONDS=0`.
- **Ephemeral `enroot start <image>`** uses a throwaway clone instead of `squashfuse + overlay`. Faster startup; ZFS pool sees brief dataset churn.
- **`enroot load docker://`** does not require `ENROOT_NATIVE_OVERLAYFS=y`. The layer-stacking path is ZFS clones rather than `enroot-mksquashovlfs`.

`WARM_SECONDS=0` and no quota collapses the template-cache design to refcount-on-remove behavior — equivalent in disk economics to today's `dir` backend, but with all the clone-on-create, ephemeral-start, and Docker-layer-stacking wins still active.

When `ENROOT_STORAGE_BACKEND=dir` (the default), behavior is byte-for-byte identical to today.
