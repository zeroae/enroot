# ZFS storage backend

This document describes an optional ZFS-aware mode for the enroot container store. **Plan A (foundation) is implemented**: `enroot create` and `enroot remove` use ZFS datasets when `ENROOT_STORAGE_BACKEND=zfs`. The remaining substitutions (template warm/cold lifecycle, `.zfs` file format, `zfs://` URI, ephemeral-start ZFS path, Docker layer stacking on ZFS) are tracked under `doc/plans/`. The default storage backend (plain directories under `ENROOT_DATA_PATH`) is unchanged and remains the only option on hosts without ZFS.

## Motivation

Today, `enroot create foo.sqsh -n NAME` does a fresh `unsquashfs` of the entire image into `${ENROOT_DATA_PATH}/NAME`. Two creates from the same image produce two independent, fully-extracted copies on disk; nothing is shared. On HPC nodes where many users run containers built from a small set of common base images (CUDA, PyTorch, Ubuntu LTS), this wastes both extraction time and disk space.

The ZFS backend is an *alternative storage driver*, in the same spirit as Docker's pluggable storage drivers (`overlay2`, `zfs`, `btrfs`, …). When configured, it substitutes ZFS-native operations for three of enroot's storage code paths — `create`, ephemeral `start <image>`, and `load docker://` — replacing extraction-per-create with extract-once-then-clone, and replacing overlay-on-squashfuse with throwaway clones. Hosts without ZFS, and the default `dir` backend on ZFS hosts, are untouched.

## Configuration knobs

| Setting | Default | Description |
| ------ | ------ | ------ |
| `ENROOT_STORAGE_BACKEND` | `dir` | `dir` = today's behavior. `zfs` = use ZFS datasets for the container store. |
| `ENROOT_TEMPLATE_WARM_SECONDS` | `604800` (7 days) | How long a template with no clones remains evictable only under pressure. `0` = evict immediately when refcount reaches zero (refcount-only). `inf` = never auto-evict. |
| `ENROOT_TEMPLATE_PRESSURE_THRESHOLD` | `0.80` | Templates dataset quota fraction above which routine `create`s start evicting warm templates. Soft signal; the ZFS quota is the hard wall. |

When `ENROOT_STORAGE_BACKEND=zfs`, `ENROOT_DATA_PATH` must be the mountpoint of a ZFS dataset that the unprivileged user has been granted permission on (see [Admin setup](#admin-setup)).

## Store layout

```
${pool}/${dataset}/templates/<sha256>            # one per distinct image content
${pool}/${dataset}/templates/<sha256>@pristine   # snapshot taken after extraction
${pool}/${dataset}/<user>/<container_name>       # clones of @pristine, the user's containers
```

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
   zfs allow user create,mount,clone,destroy,snapshot,rename tank/enroot
   zfs allow user receive tank/enroot/templates
   ```

   `zfs receive` from `.zfs` files and `zfs://` requires this delegation. Without it, the ZFS backend operates only on already-received templates.

   **Linux mount(2) caveat:** ZFS delegation governs ZFS's *internal* logic, but on Linux the kernel `mount(2)` syscall still requires `CAP_SYS_ADMIN`. As a result, an unprivileged user invoking `enroot create` on the ZFS backend will see "filesystem successfully created, but it may only be mounted by root" warnings, and the dataset will not be auto-mounted. The two practical workarounds:

   - **Privileged `create`, unprivileged everything else.** Run `enroot create` (and `enroot load`) as root or via sudo; `enroot start`, `exec`, and `remove` work unprivileged because they operate on already-mounted datasets or use mount-namespace tricks that don't need additional CAP_SYS_ADMIN.
   - **`fs.namespace.unprivileged_userns_clone=1` + per-user mount namespace.** A wrapper that enters a user namespace before `enroot create` lets the ZFS auto-mount succeed without root, at the cost of complexity and a small overhead.

   On hosts where the same operator runs `create` and `start`, the privileged-create approach is simpler and matches enroot's existing model where image conversion (`enroot import`/`enroot-aufs2ovlfs`) already requires elevated privileges.

4. **Configure `ENROOT_STORAGE_BACKEND=zfs`** in `enroot.conf` (or per-user). Set `ENROOT_DATA_PATH` to the mountpoint of `tank/enroot` (or per-user subdataset).

5. **For `zfs://` transport**, ensure passwordless SSH between hosts; standard `ssh_config` Host blocks (port, identity, jump hosts) are honored.

6. **For Docker layer stacking on ZFS** (`enroot load docker://...`), no extra setup beyond the delegations above. The ZFS backend obviates the `ENROOT_NATIVE_OVERLAYFS=y` requirement that the `dir` backend imposes for `enroot load`.

## Where the ZFS backend is used

When `ENROOT_STORAGE_BACKEND=zfs`, ZFS substitutes for the existing storage code paths in three places. The overlayfs and `fuse-overlayfs` paths are not removed — they continue to serve the `dir` backend and any host without ZFS.

| Subsystem | `dir` backend | `zfs` backend |
| ------ | ------ | ------ |
| `enroot create foo.sqsh` | `unsquashfs` into `<store>/<NAME>` | Extract once into `templates/<sha>`, `zfs clone templates/<sha>@pristine <user>/<NAME>`. |
| `enroot start foo.sqsh` (ephemeral; no prior `create`) | `squashfuse` lower layer + overlay upper layer, with kernel `overlay` or `fuse-overlayfs` selected by `ENROOT_NATIVE_OVERLAYFS`. | Ensure template, `zfs clone @pristine` to a unique ephemeral name, `zfs destroy` on exit. |
| `enroot load docker://` (fetch + create in one step) | Layer-stack via `enroot-mksquashovlfs` overlay; requires `ENROOT_NATIVE_OVERLAYFS=y`. | Stack Docker layers as a chain of ZFS datasets — for each layer in order, `zfs clone parent@done` produces a writable child, the layer tarball is extracted into it with whiteout handling, then `zfs snapshot @done`. The leaf snapshot becomes the template's `@pristine`. Mirrors Docker's own `zfs` storage driver. |

`ENROOT_NATIVE_OVERLAYFS` keeps its current meaning when the backend is `dir`. When the backend is `zfs`, the knob is irrelevant for the three substituted paths above (overlay is not used), but it continues to control overlay choice for any code path that does not yet have a ZFS substitution.

The `ENROOT_NATIVE_OVERLAYFS=y` precondition for `enroot load docker://` is **not required** when the ZFS backend is active — ZFS layer-stacking does not depend on kernel overlayfs.

## Behavior change vs. today

When `ENROOT_STORAGE_BACKEND=zfs`:

- **`enroot remove`** no longer reclaims template storage immediately. Reclamation happens on the next `create` (cold sweep) or whenever the warm period expires under pressure. Sites that need eager reclamation should set `ENROOT_TEMPLATE_WARM_SECONDS=0`.
- **Ephemeral `enroot start <image>`** uses a throwaway clone instead of `squashfuse + overlay`. Faster startup; ZFS pool sees brief dataset churn.
- **`enroot load docker://`** does not require `ENROOT_NATIVE_OVERLAYFS=y`. The layer-stacking path is ZFS clones rather than `enroot-mksquashovlfs`.

`WARM_SECONDS=0` and no quota collapses the template-cache design to refcount-on-remove behavior — equivalent in disk economics to today's `dir` backend, but with all the clone-on-create, ephemeral-start, and Docker-layer-stacking wins still active.

When `ENROOT_STORAGE_BACKEND=dir` (the default), behavior is byte-for-byte identical to today.
