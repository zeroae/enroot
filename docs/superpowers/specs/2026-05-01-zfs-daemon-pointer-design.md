# ZFS pointer-format import for `dockerd://` and `podman://` URIs

**Goal:** Extend the ZFS pointer-format cache (zfs.4) so `enroot import dockerd://<image>` and `enroot import podman://<image>` get the same cache-hit behavior as `enroot import docker://<ref>`. Repeat imports of the same daemon-local image populate the layer-keyed template cache once and clone subsequent times.

**Status:** Approved-by-conversation 2026-05-01. Ready for implementation plan.

## 1. Problem

Post-zfs.4, `enroot import docker://<ref>` writes a 1 KiB pointer file and skips `mksquashfs` entirely; repeat imports hit the existing template cache via `image-config-sha256`. But `dockerd://*` and `podman://*` URIs still go through `docker::daemon::import`, which does:

```
${engine} create → ${engine} export | tar -x → rootfs/ → mksquashfs → .sqsh
```

There's no template population, no pointer, no cache. Repeat imports of the same daemon-local image redo the full export + squash every time. Pyxis-driven workflows that pull from a local podman registry (a common HPC pattern when registries are airgapped) get none of the zfs.4 win.

## 2. Goal

`enroot import dockerd://<image>` and `enroot import podman://<image>` (when ZFS backend is active and `ENROOT_ZFS_IMPORT_FORMAT=pointer`):

1. Populate a ZFS template keyed by the daemon-reported image ID (sha256 of the image config).
2. Write a pointer file at the requested output path. Pyxis treats it identically to a `docker://`-sourced pointer.
3. On `enroot create`, the pointer-create path clones the template — `O(zfs clone)`.
4. Eviction recovery re-runs `${engine} export` to repopulate the template, validating the freshly-resolved image ID matches the pointer's claim.

`docker://` behavior is unchanged. `--format=squashfs` opt-out preserves the legacy `mksquashfs`-based path. `dir` backend is untouched.

## 3. Approach

### 3.1 Cache key

`${engine} inspect --format='{{.Id}}' <image>` returns `sha256:<64-hex>`. Stripping the `sha256:` prefix gives a 64-hex string identical in shape and meaning to the `image-config-sha256` we already use for `docker://` imports. Use it as the cache key — same dataset naming convention, same template directory layout.

For images that the daemon pulled from a registry, this matches the `image-config-sha256` we'd compute on a `docker://` import of the same reference. For locally-built images, it's still a stable content hash. Either way, it's the right cache key.

### 3.2 New install path: flat directory → template

`zfs::_install_template_from_layers` (zfs.4) merges N layered overlayfs layers into a `.tmp` dataset. For daemon imports we already have a flat rootfs from `${engine} export | tar -x`, so we don't need overlayfs at all.

Add a new helper:

```bash
zfs::_install_template_from_dir <cache_key> <source_dir> <unpriv>
```

Same atomicity / race / snapshot / readonly tail as `_install_template_from_layers`, but the merge step is a single `tar -C "${source_dir}" -cpf - . | tar -C "${mountpoint}" -xpf -` (or a direct `mv`/rsync — whichever is simplest and matches existing project conventions). Returns the template path on stdout.

### 3.3 New top-level: `zfs::import_daemon_pointer`

```bash
zfs::import_daemon_pointer <uri> <output_path> <arch>
```

Subshell function (matches `zfs::import_docker_pointer` style). Body:

1. Parse `uri` → `engine` (`docker` / `podman`) and `image`.
2. `common::checkcmd jq "${engine}" tar` (drop `mksquashfs` — we don't need it).
3. `${engine} inspect "${image}"` → image ID, arch, config (uses existing `docker::configure`).
4. Strip `sha256:` from image ID → `cache_key`.
5. Verify arch matches the request (warn-only, same as `docker::configure`).
6. Trap + tmpdir + `${engine} create` + `${engine} export | tar -x rootfs/` + `docker::configure rootfs config "${arch}"`.
7. `zfs::_install_template_from_dir "${cache_key}" "${PWD}/rootfs" "${unpriv}"`.
8. `zfs::set_template_metadata "${template}" "${uri}" "" "${arch}"` — note empty manifest-digest.
9. `zfs::write_pointer "${output_path}" "${cache_key}" "" "${arch}" "${uri}"` — empty manifest-digest.

### 3.4 Pointer schema: optional `manifest-digest`

Daemon-local images don't have a registry manifest digest. The pointer format must accommodate that. Schema evolution (still v1 — backwards compatible with all zfs.4 pointers):

- `write_pointer`: when `manifest_digest` is empty, OMIT the line entirely (don't write `manifest-digest=`).
- `read_pointer`: `manifest-digest` becomes optional. If present, validate as before; if absent, treat as empty string.
- The URI regex widens from `^docker://[A-Za-z0-9._:/@+-]+$` to `^(docker|dockerd|podman)://[A-Za-z0-9._:/@+-]+$`.

A v4-era pointer (with `manifest-digest`) is still valid under the relaxed reader. A new daemon-import pointer (without it) parses cleanly. No magic line bump.

### 3.5 Eviction recovery for daemon URIs

`zfs::create_from_pointer` currently dispatches to `zfs::_pull_and_install_template` (which assumes docker://). Refactor:

```bash
case "${uri}" in
    docker://*)
        fresh_config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}") ;;
    dockerd://*|podman://*)
        fresh_config_sha=$(zfs::_extract_and_install_from_daemon "${uri}" "${arch}") ;;
    *)
        common::err "Pointer ${pointer_path} has unsupported URI: ${uri}" ;;
esac
```

The new `zfs::_extract_and_install_from_daemon` helper does the same body as `import_daemon_pointer` minus the `write_pointer` step, returns the cache_key.

### 3.6 Wire `runtime::import`

Add a parallel branch in the import dispatcher:

```bash
case "${uri}" in
docker://*)
    if zfs::pointer_format_active; then ... import_docker_pointer
    else docker::import
    fi ;;
dockerd://* | podman://*)
    if zfs::pointer_format_active; then
        # filename defaulting (mirror docker::daemon::import's derivation)
        zfs::import_daemon_pointer "${uri}" "${filename}" "${arch}"
    else
        docker::daemon::import "${uri}" "${filename}" "${arch}"
    fi ;;
zfs://*) ... unchanged
*) ... unchanged
esac
```

### 3.7 Doc

`doc/zfs.md` already documents the pointer format and inspection recipe. Add a one-paragraph note that `dockerd://` and `podman://` URIs participate in the same cache; the pointer's `enroot:uri` field will show the daemon URI; `manifest-digest` is empty for these.

## 4. Files affected

| File | Change |
|---|---|
| `src/storage_zfs.sh` | New `zfs::_install_template_from_dir`. New `zfs::import_daemon_pointer`. New `zfs::_extract_and_install_from_daemon`. Refactor `zfs::create_from_pointer` recovery branch on URI scheme. Relax URI regex in `write_pointer` and `read_pointer`. Make `manifest-digest` optional in both functions. |
| `src/runtime.sh` | New `dockerd://*\|podman://*` branch in `runtime::import` that calls `zfs::import_daemon_pointer` when pointer format is active. |
| `doc/zfs.md` | One-paragraph note about daemon-URI cache parity. |

No CLI changes. No `Makefile` / version bump (refinement; ships in next zfs.5 release whenever that lands).

## 5. Trust / security

The pointer regex relax keeps the same shell-metachar exclusion; only the scheme prefix widens. Image IDs from `${engine} inspect` are validated as `^[0-9a-f]{64}$` before they touch any property or pointer field. The empty `manifest-digest` skips its regex entirely (no value, no value to attack).

`zfs::set_template_metadata` (zfs.5 unreleased branch's helper) currently sets `enroot:manifest-digest` unconditionally. Make it skip the property-set when the value is empty so daemon templates don't carry a confusing empty `enroot:manifest-digest=` property.

## 6. Out of scope

- Reproducing the layer cache (`ENROOT_CACHE_PATH`) for daemon URIs. Daemon images are already in the daemon's layer store; we don't try to dedupe across layers.
- Cross-format conversion (e.g. importing the same image as both `docker://` and `dockerd://` and sharing the cache). Each path computes `image-config-sha256` from a different source — for daemon-pulled images they'll match, but we don't *enforce* it. If they happen to match (which they will for registry-pulled daemon images), they share the cache for free.
- Dockerd/podman-specific provenance fields (e.g. layer count, parent image). Not needed for the cache key.

## 7. Acceptance

- `enroot import dockerd://ubuntu:24.04 -o /tmp/d.sqsh` writes a < 1 KiB pointer with magic line `enroot-zfs-image:v1`, no `manifest-digest=` line, `enroot-zfs-image:v1`'s `uri=dockerd://...`, populates `${POOL}/.templates/<image-id>`.
- Repeat `enroot import dockerd://ubuntu:24.04 -o /tmp/d.sqsh` hits the cache (no new template; "Reusing cached template" log).
- `enroot create -n c1 /tmp/d.sqsh` is `O(zfs clone)` (subseconds).
- `zfs get enroot:uri ${POOL}/.templates/<image-id>` shows `dockerd://ubuntu:24.04`.
- Eviction recovery: destroy the template, re-run `enroot create -n c2 /tmp/d.sqsh`, verify it re-extracts from the daemon and clones successfully.
- `docker://` behavior is unchanged.
- `--format=squashfs` opt-out still produces a real squashfs for daemon URIs.
