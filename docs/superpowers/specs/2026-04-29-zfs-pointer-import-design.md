# ZFS pointer-format import design

**Issue:** [#13](https://github.com/zeroae/enroot/issues/13) — ZFS backend: stable template key for repeat `enroot import docker://` invocations (pyxis workflow).

**Status:** Approved design (2026-04-29). Ready for implementation plan.

## 1. Problem

The ZFS backend already clones existing templates instantly when `enroot create` is given the *same* `.sqsh` file twice. But pyxis's workflow is `enroot import docker://<ref>` (writes a transient `.sqsh` to `/run/pyxis/<uid>/<jobid>.<step>.squashfs`, deleted immediately after `create`) followed by `enroot create <that.sqsh>`. Each import runs `mksquashfs`, whose output bytes vary across invocations even when the underlying image is identical (squashfs internal timestamps and per-build metadata leak through). The resulting `.sqsh` therefore has a different sha256 every time, and the template cache (keyed by `sha256(.sqsh)`) misses on every job.

The repro on Ubuntu 24.04 / arm64 / zenroot 4.1.2.zfs.3 shows two distinct templates of identical size for the same `ubuntu:24.04` image after two `srun --container-image=ubuntu:24.04` invocations, each ~38 s.

## 2. Goal

Two consecutive `srun --container-image=docker://<ref>` invocations of the same image reference resolve to the same template dataset under `${pool}/${dataset}/.templates/`. The second invocation's `enroot create` is `O(zfs clone)` — subseconds — not `O(extract image)`. The fix is transparent to pyxis (no SPANK plugin changes, no new pyxis flags). The default `dir` backend is untouched.

## 3. Approach

Replace the `.sqsh` file produced by `enroot import docker://<ref>` with a small magic-prefixed **pointer file** when the ZFS backend is active. The pointer carries the `image-config-sha256` (the same stable cache key that `zfs::docker_install_from_layers` already uses for direct `enroot create docker://X` calls). Import populates the layer-keyed template cache as a side effect and **skips `mksquashfs` entirely**. `enroot create` magic-byte-sniffs the pointer, looks up the template by `image-config-sha256`, and clones.

The win is twofold:

- **Import path** no longer runs `mksquashfs` (the dominant cost of the docker import step on multi-GB images).
- **Create path** skips `unsquashfs` — clones an already-extracted template instead.

The existing `zfs::docker_install_from_layers` path (used by direct `enroot create docker://X`) is reused unchanged. No new cache machinery, no new key scheme.

### 3.1 Why pyxis is unaffected

Pyxis treats the `.sqsh` as a strictly transient handoff: it writes to a per-uid runtime dir (`%s/%u/%u.%u.squashfs` in `pyxis_slurmstepd.c:1231`), feeds the path to `enroot create`, and `unlink()`s it immediately afterward (`pyxis_slurmstepd.c:731`–`736`). Pyxis never reads the file's content. Replacing the squashfs bytes with a 1-KiB pointer file at the same path is invisible to pyxis.

### 3.2 Why the existing `dir` backend is unaffected

The pointer code path runs only when `ENROOT_STORAGE_BACKEND=zfs`. On `dir`, `enroot import docker://<ref>` continues to call `mksquashfs` and produce a real `.sqsh`, exactly as today.

## 4. Pointer file format

Plain text, magic-prefixed, written atomically (`tmp + rename`). Filename stays whatever the user / pyxis requested (`.sqsh` is conventional and pyxis-hardcoded).

```
enroot-zfs-image:v1
image-config-sha256=<64-hex>
manifest-digest=sha256:<64-hex>
arch=<arm64|amd64|ppc64le|...>
uri=docker://<registry>/<repo>:<tag>
imported=<RFC3339 UTC>
```

| Field | Required | Purpose |
|---|---|---|
| Magic line `enroot-zfs-image:v1` | yes | First 19 bytes. `enroot create` reads exactly these and dispatches to the pointer code path. Distinguishable from any squashfs (squashfs magic is `\x68\x73\x71\x73`). |
| `image-config-sha256` | yes | Cache key. Matches the existing `zfs::docker_install_from_layers` key. |
| `manifest-digest` | yes | Informational (debug / `enroot info`). Not used as a cache key. |
| `arch` | yes | The `--arch` value used at import time. Threaded back into `docker::pull_layers_only` on eviction recovery so the right manifest is pulled. |
| `uri` | yes | Enables eviction recovery: if the template was reaped by warm/cold sweep before `create`, re-pull from this URI. |
| `imported` | yes | RFC3339 UTC timestamp. Diagnostic. |

Body is < 1 KiB. Any unrecognized fields are ignored (forward compatibility).

### 4.1 Magic bytes are sufficient

The 19-byte ASCII magic prefix `enroot-zfs-image:v1\n` cannot collide with squashfs (`\x68\x73\x71\x73...`), zfs send streams (which begin with `\x00\x00\x00\x00\xb5\xff...` after a few framing bytes), or any other format `enroot create` accepts today. A simple `read -n 19` and string compare is enough — no probabilistic detection.

## 5. Components

The implementation lives almost entirely in `src/storage_zfs.sh`, with two minimal hooks in `src/runtime.sh` and one optional refactor in `src/docker.sh`.

### 5.1 `src/storage_zfs.sh` — new functions

- **`zfs::pointer_format_active`** — returns 0 if `ENROOT_STORAGE_BACKEND=zfs` and `ENROOT_ZFS_IMPORT_FORMAT` is unset or set to `pointer`. Returns 1 otherwise.
- **`zfs::write_pointer <output_path> <config_sha> <manifest_digest> <arch> <uri>`** — atomic `tmp + rename` write of the pointer file with the schema in §4. Sets `imported` to `date -u +%FT%TZ`.
- **`zfs::is_pointer <path>`** — magic-byte check. Reads first 19 bytes; returns 0 on match.
- **`zfs::read_pointer <path>`** — parses key=value lines after the magic line, prints `KEY=value` pairs to stdout for caller `eval`. Validates required fields against strict regexes (hex sha for `image-config-sha256` and `manifest-digest`; allow-listed `arch`; `uri` must start with `docker://`) and rejects malformed input.
- **`zfs::template_exists <config_sha>`** — predicate. Returns 0 iff `${pool}/${dataset}/.templates/<config_sha>@<pristine_snap>` exists. Cheap (single `zfs list`).
- **`zfs::import_docker_pointer <uri> <output_path> <arch>`** — orchestrates the new import flow:
  1. `docker::pull_layers_only <uri> <arch>` → resolves `image-config-sha256`, `manifest-digest`, `layer-count`, `unpriv` flag, and the layer-cache directory path. (Function name negotiable; see §5.3.)
  2. `zfs::docker_install_from_layers "${config_sha}" "${layer_count}" "${unpriv}" "${config_sha}"` — populates `${pool}/${dataset}/.templates/<config_sha>` if absent and clones into a transient name `<config_sha>`; immediately destroy that clone (we want the template only — clone is a side-effect of the existing function we should remove from this code path). **Note for plan author:** consider factoring `zfs::docker_install_from_layers` into `install` + `clone` halves so this code path doesn't need to create-then-destroy a throwaway clone. See §11.
  3. `zfs::write_pointer "${output_path}" "${config_sha}" "${manifest_digest}" "${arch}" "${uri}"`.
- **`zfs::create_from_pointer <pointer_path> <name>`** — orchestrates the create-from-pointer flow:
  1. `zfs::read_pointer` → extract `config_sha`, `manifest_digest`, `arch`, `uri`.
  2. **Hit path:** `zfs::template_exists "${config_sha}"` → `zfs::touch_template`; `zfs::clone_container "${config_sha}" "${name}"`. Done.
  3. **Miss path (eviction recovery):** `docker::pull_layers_only "${uri}" "${arch}"`; validate the freshly-pulled `image-config-sha256` equals the pointer's claim (else error — registry tag has been republished and the pointer is stale); then `zfs::docker_install_from_layers "${config_sha}" "${layer_count}" "${unpriv}" "${name}"` (which re-populates the template and performs the user-named clone in one shot).

### 5.2 `src/runtime.sh` — two hooks

- **`runtime::import`** (currently dispatches `docker://` → `docker::import`): add a branch `if zfs::pointer_format_active && uri matches docker://...; then zfs::import_docker_pointer`. Otherwise unchanged.
- **`runtime::create`** (input file may be `.sqsh` or `.zfs` send-stream): magic-byte sniff at the top. If `zfs::is_pointer "${image}"` → `zfs::create_from_pointer`. Otherwise unchanged. If pointer detected but `ENROOT_STORAGE_BACKEND != zfs`, error with: `error: ${image} is a ZFS pointer file; ENROOT_STORAGE_BACKEND=zfs is required to use it`.

### 5.3 `src/docker.sh` — minor refactor

Today `docker::import` does pull-layers + mksquashfs in one function. Factor out:

- **`docker::pull_layers_only <uri> <arch>`** — returns (via stdout key=value or globals) `image-config-sha256`, `manifest-digest`, `layer-count`, `unpriv`, and the layer-cache directory path. No `mksquashfs` invocation.

`docker::import` (the existing function used by the `dir` backend) is rewritten as `docker::pull_layers_only` + `mksquashfs`, so its observable behavior is unchanged. If this refactor is too invasive in a single PR, an alternative is to add `docker::pull_layers_only` as a near-copy of the pull portion of `docker::import` and address the duplication later — call this out in the implementation plan as a tradeoff for the implementer.

### 5.4 `enroot.in` — CLI flag

Add `--format <pointer|squashfs>` to `enroot import`. Default is `pointer` when ZFS backend is active and URI is `docker://`; `squashfs` everywhere else. Help text updated. The same effect is also reachable via `ENROOT_ZFS_IMPORT_FORMAT`.

## 6. Data flow

### 6.1 Import (ZFS backend, `docker://`, default format)

```
enroot import docker://ubuntu:24.04 -o /tmp/u.sqsh
  └─ runtime::import
       └─ zfs::pointer_format_active? yes
            └─ zfs::import_docker_pointer
                 ├─ docker::pull_layers_only docker://ubuntu:24.04 arm64
                 │     ├─ fetch manifest
                 │     ├─ fetch image config blob   → image-config-sha256
                 │     └─ fetch layer blobs into ENROOT_CACHE_PATH
                 ├─ zfs::docker_install_from_layers <config_sha> 5 0 <config_sha>
                 │     ├─ template hit?  (idempotent; no-op on second call)
                 │     └─ template miss: zfs create + extract layers + snapshot
                 └─ zfs::write_pointer /tmp/u.sqsh <config_sha> <manifest_digest> arm64 <uri>
```

Total disk I/O on second import of the same image: just the manifest and config blob (a few KB each). No layer re-download (already cached). No `mksquashfs`. No template extraction. Pointer rewrite is a 1-KiB rename.

### 6.2 Create (pointer)

```
enroot create -n u1 /tmp/u.sqsh
  └─ runtime::create
       └─ zfs::is_pointer? yes
            └─ zfs::create_from_pointer
                 ├─ zfs::read_pointer  → config_sha, manifest_digest, arch, uri
                 ├─ zfs::template_exists <config_sha>?  yes
                 ├─ zfs::touch_template <template>
                 └─ zfs::clone_container <config_sha> u1   (subseconds)
```

### 6.3 Create (pointer, evicted template)

```
enroot create -n u1 /tmp/u.sqsh
  └─ runtime::create
       └─ zfs::create_from_pointer
            ├─ zfs::read_pointer
            ├─ zfs::template_exists <config_sha>?  no  (evicted)
            ├─ recover: docker::pull_layers_only <uri> <arch>
            │     ├─ refetches manifest + config blob (validates config_sha matches pointer)
            │     └─ may need network if layers also evicted from ENROOT_CACHE_PATH
            └─ zfs::docker_install_from_layers <config_sha> <layer_count> <unpriv> u1
                  ├─ re-populate template
                  └─ clone into u1
```

If the registry is unreachable during recovery, error with the URI in the message: `error: ZFS template <config_sha[:12]> evicted; failed to re-pull from <uri>: <reason>`.

### 6.4 Create (legacy real `.sqsh`)

`runtime::create` magic-byte-sniffs, sees no pointer header, falls through to existing `zfs::ensure_template` (sqsh-sha keyed) — current behavior. Existing `.sqsh` files keep working.

## 7. Configuration

| Knob | Where | Values | Default | Effect |
|---|---|---|---|---|
| `ENROOT_ZFS_IMPORT_FORMAT` | `enroot.conf` or env | `pointer`, `squashfs` | `pointer` | When ZFS backend is active and URI is `docker://`, controls whether `enroot import` writes a pointer or a real `.sqsh`. Ignored on `dir` backend. |
| `--format <pointer\|squashfs>` | `enroot import` flag | same | inherits env | Per-invocation override. |

Existing knobs (`ENROOT_TEMPLATE_WARM_SECONDS`, `ENROOT_TEMPLATE_PRESSURE_THRESHOLD`) apply unchanged — pointers participate in the same warm/cold lifecycle through the templates they reference.

## 8. Trust and security

- Pointer files are read by the calling user (the same user that wrote them). No new privileged-helper interactions; `enroot-zfs-mount` is unchanged.
- A malicious pointer cannot escalate privilege:
  - It carries a docker URI (the user could pass that directly to `enroot create docker://...` anyway).
  - It carries an `image-config-sha256`. `zfs::create_from_pointer` cross-validates this against the template dataset (which is named after that sha and exists in `${pool}/${dataset}/.templates/`); a pointer claiming `config_sha=X` cannot be used to clone an unrelated dataset because the dataset name *is* the cache key.
  - Pointer fields are never passed to a shell unquoted. `zfs::read_pointer` validates each field against a regex (`image-config-sha256` and `manifest-digest` must be 64 hex; `arch` must match a known set; `uri` must start with `docker://`) and rejects the file otherwise.
- Pointer content is plaintext; there is no signature. We rely on filesystem permissions (the file lives in user-owned space) to prevent tampering. This matches today's posture for `.sqsh` files (also unsigned).

## 9. Testing

There is no automated test suite in the project. Verification is end-to-end on a ZFS-backed test cluster.

### 9.1 Smoke checks (any ZFS-backed node)

1. **Pointer import.** `enroot import docker://ubuntu:24.04 -o /tmp/u.sqsh` → file size < 1 KiB; first line is `enroot-zfs-image:v1`; one new template under `${pool}/${dataset}/.templates/`.
2. **Pointer create, hit.** `enroot create -n u1 /tmp/u.sqsh` → completes in < 1 s; container dataset is a clone of the template snapshot.
3. **Idempotent re-import.** `rm /tmp/u.sqsh && enroot import docker://ubuntu:24.04 -o /tmp/u.sqsh` → no new template; pointer file matches the first import's `image-config-sha256`.
4. **Pyxis flow.** `srun --container-image=docker://ubuntu:24.04 cat /etc/os-release` twice → second run < 1 s create step; only one template under `.templates/` after both runs (the failure mode the issue calls out).
5. **Eviction recovery.** `sudo zfs destroy -r ${pool}/${dataset}/.templates/<config_sha>` then `enroot create -n u2 /tmp/u.sqsh` → re-pulls from registry, succeeds. (Set `ENROOT_TEMPLATE_WARM_SECONDS=0` to also exercise the warm-sweep path.)
6. **Format opt-out.** `enroot import --format=squashfs docker://ubuntu:24.04 -o /tmp/u.sqsh` → real squashfs, no pointer magic, no template population by import. `enroot create` still works (legacy sqsh-sha path).
7. **Wrong-backend error.** Copy pointer to a `dir`-backend node; `enroot create -n u3 /tmp/u.sqsh` → exits with the §5.2 error message.

### 9.2 Negative checks

8. **Malformed pointer.** Truncate the magic line / break a field's hex format → `enroot create` errors with a parse message naming the bad field; does not fall through to extraction.
9. **Pointer with stale `arch`.** Import on arm64, attempt create on amd64 (e.g., copy pointer across) → eviction-recovery pull respects the pointer's `arch`; create succeeds on the amd64 node by re-pulling that arch.
10. **Backwards compat.** Pre-existing real `.sqsh` files (no magic line) still work — both as sqsh-sha-keyed inputs to `enroot create` on ZFS, and on `dir` backend.

### 9.3 Performance acceptance (issue §"What good looks like")

11. Two `srun --container-image=ubuntu:24.04 hostname` invocations on a fresh node: first run < cold-time-baseline; second run create-step < 1 s.
12. After the runs, `zfs list -r ${pool}/${dataset}/.templates` shows **one** template per unique image (not one per import).

## 10. Out of scope

- `dir` backend behavior. Untouched.
- pyxis SPANK plugin changes. Not required.
- Cross-node pointer transport. Pointers are valid only on the node whose ZFS pool holds the referenced template. For multi-node, operators continue to use either `--format=squashfs` (real portable artifact) or the existing `zfs://<host>/<name>` send-stream transport.
- Garbage collection of orphaned pointer files. Pyxis already `unlink()`s them; standalone CLI users delete their own. No new GC machinery.
- `enroot export` of pointer-imported containers. The clone is a real ZFS dataset, so `enroot export --format=squashfs` continues to work via the existing `mksquashfs` path; `--format=zfs` continues to work via `zfs send`. No pointer-specific export semantics.
- Deterministic `mksquashfs` (rejected as alternative C in brainstorming — saves nothing on import).

## 11. Open questions

None blocking implementation. Three minor calls deferred to the plan author:

- **`docker::import` refactor scope.** Single PR factoring out `docker::pull_layers_only` cleanly, vs. duplicating the pull portion in `storage_zfs.sh` and addressing duplication later. Either is fine; the plan should pick one and justify briefly.
- **Layer-cache eviction during recovery.** If both the template *and* the layer cache (`ENROOT_CACHE_PATH`) are evicted, recovery does a full registry re-pull. This is correct behavior, just slower than expected. Not worth special-casing.
- **Splitting `zfs::docker_install_from_layers` into `install` + `clone`.** Today it does both. The new pointer-import path wants the install-only half (it doesn't need a clone — it just wants the template populated). The plan can either (a) split the function and have `import_docker_pointer` call only the install half, or (b) call the full function with the config-sha as the clone-name and immediately destroy that throwaway clone. (a) is cleaner; (b) is one fewer touchpoint. Plan picks one.

## 12. Compatibility and rollout

- New `ENROOT_ZFS_IMPORT_FORMAT=squashfs` opt-out preserves the pre-change behavior bit-for-bit if needed.
- Pointer files are not portable to older `enroot` versions. Operators bridging old/new nodes should set `ENROOT_ZFS_IMPORT_FORMAT=squashfs` on the new ones, or use `zfs://` transport.
- Version bump: this is the v4.1.2.zfs.4 line. Document the new knob in `doc/zfs.md` and the changelog.
