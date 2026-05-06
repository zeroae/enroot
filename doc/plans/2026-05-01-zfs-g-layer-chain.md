# ZFS Backend Plan G: Per-layer ZFS Clone Chain (opt-in)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `ENROOT_STORAGE_BACKEND=zfs` AND `ENROOT_ZFS_LAYER_CHAIN=y`, populate the Docker template cache via a per-layer `zfs clone` chain instead of a single merged extract. Each registry layer becomes its own `<store>/.layers/<layer-digest>` dataset, layered as cloned descendants of the layer below. The leaf is then cloned into `<store>/.templates/<image-config-sha>` to preserve the Plan F template shape. With the flag unset, Plan F's single-merge path runs unchanged.

**Why:** Plan F's single-merge design re-extracts every layer for every distinct image. For HPC and CI hosts that pull many images sharing a Debian/Alpine/CUDA base, this wastes disk, CPU, and bandwidth. Per-layer chains buy back:

1. Cross-image layer dedup at the dataset level — two images sharing a base store the base bytes once. (`dedup=on` recovers this in Plan F at ~5 GB RAM per TB; per-layer datasets dedup for free.)
2. Cheap incremental re-pull — when the top layer of a tag changes, only that layer is rebuilt; lower-layer datasets are reused.
3. Layer-granular cache invalidation and inspection (`zfs list -r <store>/.layers` shows the chain).
4. Quota accounting that matches intuition (shared layers count once).
5. Aligns with Docker's own `zfs` storage driver.

Tradeoff: shell-side whiteout/opaque-dir merging is required because each at-rest layer dataset must contain the merged-up-to-this-layer rootfs (overlayfs only does the merge at mount time). The kernel's overlay engine is *not* the merge engine in this path — `enroot-aufs2ovlfs` already converted whiteouts to overlayfs form during `_prepare_layers`, but we have to apply them ourselves between clone steps.

**Architecture:** `docker::_prepare_layers` already extracts each registry layer into a per-layer directory (`1/`, `2/`, … `N/`) and runs `enroot-aufs2ovlfs` on each, producing overlayfs-style trees: `mknod 0:0` char devices for whiteouts and `trusted.overlay.opaque=y` xattrs for opaque dirs. With `ENROOT_SET_USER_XATTRS=y` (already set on the load path) we also get a parallel `user.overlay.opaque=y` for unprivileged paths.

For Plan G, after `_prepare_layers` returns, instead of one overlay-mount + tar-pipe into a single template (Plan F), we walk the layer list bottom-up:

```
.layers/<L1>          ← zfs create -u                   (apply layer 1 contents)
.layers/<L2>          ← zfs clone .layers/<L1>@done     (apply layer 2 on top)
.layers/<L3>          ← zfs clone .layers/<L2>@done     (apply layer 3 on top)
…
.layers/<LN>          ← zfs clone .layers/<L(N-1)>@done (apply layer N on top)
.templates/<cfg_sha>  ← zfs clone .layers/<LN>@done     (clone leaf as template)
```

Each `.layers/<digest>` dataset's `@done` snapshot is reused on subsequent imports of any image whose chain prefix matches. The final `.templates/<cfg_sha>@pristine` snapshot is identical in shape to Plan F's, so `zfs::clone_container`, the pointer-format import path, eviction recovery, `enroot export`, and `enroot import zfs://` all work unchanged.

**Why no `zfs promote`:** Promoting the leaf into the templates dataset inverts the chain — layer datasets become clones of the template, which then owns the data. That works for one image but produces a complex, image-private topology that defeats the whole point of cross-image sharing. Plan G keeps layer datasets as immutable origins and templates as ordinary clones. The simple invariant: *layers are shared and never mutated; templates are per-image clones; ZFS refuses to destroy a layer dataset while any descendant clone exists, so layer GC is automatic.*

**Coexistence with Plan F:**

- `ENROOT_ZFS_LAYER_CHAIN=` (unset, empty, or anything but `y`): Plan F's `_install_template_from_layers` runs unchanged. Default behavior preserved byte-for-byte.
- `ENROOT_ZFS_LAYER_CHAIN=y`: dispatch to chain mode. Same dispatch is hit from `docker::load` and from `_pull_and_install_template` (the puller used by pointer-format import and eviction recovery), so all callers see chain-mode templates when the flag is on.
- The fast path "template `@pristine` already exists, reuse it" is hit *before* the chain/no-chain dispatch. Templates produced under one mode are reused under the other without rebuild — only the *fill* mechanism differs on miss.

**Scope: `docker://` URIs only.** Plan G applies to registry-pulled images that go through `docker::_prepare_layers` (which produces the per-layer directories Plan G chains over). Daemon-local URIs (`dockerd://`, `podman://`) are *silently unaffected* by `ENROOT_ZFS_LAYER_CHAIN=y` — they go through `zfs::_extract_and_install_from_daemon`, which uses `${engine} export | tar -x` to produce a single flat rootfs (the daemon has already merged the layers internally; `docker export` is a flatten operation, not a layer-preserving one). That path goes through `zfs::_install_template_from_dir` and stays untouched. Bringing chain mode to daemon URIs is feasible but requires switching from `docker export` to `docker save` (which writes a tar archive containing per-layer tarballs plus a `manifest.json` describing layer order) — see Out of scope below.

**Depends on:** Plans A, B, F (template lifecycle, sweep, ENOSPC retry shape are reused).

**Prerequisite host setup:** Same as Plan F. ZFS user delegation must include `clone`. `promote` is **not** required (Plan G doesn't promote). Whiteout/xattr work runs inside `enroot-nsenter --user --remap-root --mount`, same as Plan F's merge step.

**Test images:** `docker://alpine` (1 layer, smoke); `docker://debian:stable-slim` (multi-layer with whiteouts); `docker://python:3.12-slim` and `docker://node:20-slim` (debian-bookworm-based — base layer must be physically shared).

---

## Files

- **Modify:** `src/storage_zfs.sh` — add `zfs::layer_chain_active`, `zfs::_install_layer_chain`, `zfs::_apply_layer_payload`, dispatch in `zfs::docker_install_from_layers`.
- **Modify:** `src/docker.sh` (`docker::_prepare_layers`, `docker::load`) — emit layer digest list to a caller-provided fd when chain mode is active; thread it into `zfs::docker_install_from_layers`.
- **Modify:** `doc/zfs.md` — document `ENROOT_ZFS_LAYER_CHAIN`, the `.layers/` namespace, dedup semantics, GC notes.
- **Modify:** `CLAUDE.md` — flip the active-design-proposals line.

`docker::configure`, `docker::_download`, the existing dir-backend overlay path, Plan F's `_install_template_from_layers`, the pointer-format paths, and `zfs::clone_container` are **not** modified.

---

### Task 1: Add `zfs::layer_chain_active` predicate

A small gate that callers use before opting into chain mode.

**Files:**
- Modify: `src/storage_zfs.sh` (append, near `zfs::pointer_format_active`)

- [ ] **Step 1.1: Add the predicate**

```bash
# Returns 0 iff the ZFS backend is active AND ENROOT_ZFS_LAYER_CHAIN=y.
# Callers gate the per-layer-clone-chain template-fill path on this.
# Default-off; the unset / "" / "n" cases all fall through to Plan F's
# single-merge path, preserving byte-for-byte behavior.
zfs::layer_chain_active() {
    zfs::enabled || return 1
    [ "${ENROOT_ZFS_LAYER_CHAIN-}" = "y" ]
}
```

- [ ] **Step 1.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add zfs::layer_chain_active predicate"
```

---

### Task 2: Side-emit layer digests from `docker::_prepare_layers`

Plan G needs the ordered list of registry layer content-digests as cache keys for `<store>/.layers/<digest>`. Today `_prepare_layers` only emits `config\nlayer_count\n` on stdout. Existing callers (Plan F's `_install_template_from_layers`, `docker::import`, `docker::load`'s dir branch) read exactly two lines via `common::read` and must keep working unchanged.

Adding extra stdout lines is risky: a 2-line consumer closes the pipe after its second `read`, causing SIGPIPE on the producer's third printf. Under `set -euo pipefail` in the producer subshell that surfaces as a non-zero exit, breaking existing callers.

The simplest fix: have `_prepare_layers` write the digest list to a sidecar file `./.layers` in its own cwd. Every caller already runs `_prepare_layers` inside a fresh `common::mktmpdir enroot` directory and `common::chdir`s into it, so the sidecar lives inside the per-call temp dir and is cleaned up by the caller's existing EXIT trap. Plan G's chain-mode caller does `readarray -t digests < .layers` after `_prepare_layers` returns. Non-chain callers simply ignore the file.

**Files:**
- Modify: `src/docker.sh`

- [ ] **Step 2.1: Have `_prepare_layers` write `./.layers`**

In `docker::_prepare_layers`, after `_download` has populated `${layers[@]}` and before the existing `printf "%s\n%s\n"` final output, add:

```bash
printf "%s\n" "${layers[@]}" > .layers
```

The file is one digest per line in stack order (base first, top last). It sits in the caller's temp dir, gets removed when the temp dir is.

- [ ] **Step 2.2: Commit**

```sh
git add src/docker.sh
git commit -s -m "docker: side-emit layer digests to ./.layers in _prepare_layers"
```

---

### Task 3: Add `zfs::_apply_layer_payload`

The bash payload that runs inside `enroot-nsenter --user --remap-root --mount` to apply one layer dir on top of one target dir. Returns a string suitable for `bash -c "${payload}"` from the chain installer.

Three phases:
1. **Opaque-dir clearing.** Walk the layer's directories; for each with `trusted.overlay.opaque=y` xattr, `rm -rf` the children (not the dir itself) of the corresponding dir in the target.
2. **Whiteout deletion.** For each char device 0:0 in the layer, `rm -rf` the corresponding path in the target.
3. **Content tar-pipe.** Tar the layer's contents into the target with `--xattrs --xattrs-include='*' --acls`, excluding char devices via an exclude list built from phase 2.

Why a payload string: the chain installer launches one `enroot-nsenter` per layer (or batches them), and the inside-userns work is straightforward bash. Keeping it as a single payload string avoids per-layer fork overhead beyond the necessary `enroot-nsenter` wrapping.

**Files:**
- Modify: `src/storage_zfs.sh`

- [ ] **Step 3.1: Add the payload generator**

```bash
# Generates the bash payload that applies one layer dir's whiteouts and
# contents on top of one target dir. Designed to be passed to
# `enroot-nsenter --user --remap-root --mount bash -c`.
#
# Pre-conditions on inputs (caller responsibility):
#   - layer_dir was extracted by docker::_prepare_layers and processed by
#     enroot-aufs2ovlfs, so whiteouts are mknod 0:0 char devices and
#     opaque dirs carry trusted.overlay.opaque=y (and user.overlay.opaque=y
#     when ENROOT_SET_USER_XATTRS=y was set, which the load path always does).
#   - target_dir already contains the merged contents of all layers below
#     this one.
#   - Both paths are absolute and well-formed (no embedded quotes/spaces in
#     the digest-keyed dataset paths the chain installer produces).
zfs::_apply_layer_payload() {
    local -r layer_dir="$1" target_dir="$2"
    cat <<PAYLOAD
set -euo pipefail
mount --make-rprivate /
cd '${layer_dir}'
# Phase 1: opaque-dir clearing — find dirs with trusted.overlay.opaque=y;
# clear the corresponding dir's children in the target.
getfattr -R -h --absolute-names -n trusted.overlay.opaque . 2>/dev/null \\
  | awk -F': ' '/^# file:/ { print substr(\$0, 9) }' \\
  | while IFS= read -r d; do
        rel=\${d#./}
        [ "\${rel}" = "." ] || [ -z "\${rel}" ] && rel=""
        find '${target_dir}'/"\${rel}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || :
    done
# Phase 2: whiteout deletion — char device 0:0 in layer means "delete in target".
find . -type c | while IFS= read -r wh; do
    rm -rf '${target_dir}'/"\${wh#./}"
done
# Phase 3: copy non-whiteout contents over.
find . -type c -printf '%P\\n' > /tmp/excludes.\$\$
tar -C . --exclude-from=/tmp/excludes.\$\$ --xattrs --xattrs-include='*' --acls -cpf - . \\
  | tar -C '${target_dir}' --xattrs --xattrs-include='*' --acls -xpf -
rm -f /tmp/excludes.\$\$
PAYLOAD
}
```

- [ ] **Step 3.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add _apply_layer_payload generator"
```

---

### Task 4: Add `zfs::_install_layer_chain`

The full chain-build-and-template-install lifecycle. Designed to be a drop-in replacement for `zfs::_install_template_from_layers` when chain mode is active. Same input contract (`cache_key` = image-config-sha256, `layer_count`, `unpriv`); also takes the layer-digest list as an array. Same output contract: prints the template dataset path on stdout.

Chain build (idempotent per-layer):

1. For i = 1..N:
   - If `<store>/.layers/<digest_i>@done` exists, reuse — go to next layer.
   - Else: race-safe create. Try `zfs create -u <store>/.layers/<digest_i>.tmp` (i=1) or `zfs clone -o canmount=noauto <prev>@done <store>/.layers/<digest_i>.tmp` (i≥2). On EEXIST, wait for `<store>/.layers/<digest_i>@done` (timeout 600s).
   - Mount the `.tmp` via `enroot-zfs-mount`. Run `enroot-nsenter --user --remap-root --mount bash -c "$(zfs::_apply_layer_payload layer_dir mountpoint)"`. On failure, mirror Plan B's ENOSPC retry (sweep warm templates, retry once; on second failure destroy `.tmp` and abort).
   - Unmount, `zfs rename .tmp → final`, snapshot `@done`, `set readonly=on`, set `enroot:layer-digest=<digest_i>` and `enroot:imported`.

Template install (matches Plan F shape):

2. `zfs clone -o canmount=noauto <store>/.layers/<digest_N>@done <store>/.templates/<cache_key>` (with the standard `.tmp`-then-rename race protection, identical to Plan F).
3. Snapshot `@pristine`, `set readonly=on`, stamp metadata. Done — caller (or `clone_container`) takes it from here.

**Files:**
- Modify: `src/storage_zfs.sh`

- [ ] **Step 4.1: Add chain installer**

Append after `zfs::_install_template_from_dir` in `src/storage_zfs.sh`. Inputs:

```
$1 cache_key   - image-config-sha256
$2 layer_count - the N from _prepare_layers
$3 unpriv      - "y" or "" — passed through to enroot-nsenter
$4..$(3+N)     - layer digests in stack order, base first
```

Print the resulting template dataset path on stdout (no trailing newline). Sweeps templates and runs the layer-apply ENOSPC retry on each layer.

- [ ] **Step 4.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add _install_layer_chain"
```

---

### Task 5: Dispatch chain mode in `docker_install_from_layers` and `_pull_and_install_template`

`docker::load` and the pointer-import / eviction-recovery paths both go through the install helpers. Both need to opt into chain mode when active.

**Files:**
- Modify: `src/storage_zfs.sh`

- [ ] **Step 5.1: Make `docker_install_from_layers` chain-mode-aware**

Currently:

```bash
zfs::docker_install_from_layers() {
    local -r cache_key="$1" layer_count="$2" unpriv="$3" name="$4"
    local template
    template=$(zfs::_install_template_from_layers "${cache_key}" "${layer_count}" "${unpriv}")
    zfs::clone_container "${template}" "${name}"
}
```

Add an optional 5th-onwards argument: layer digests (variadic). When `zfs::layer_chain_active`, route through `_install_layer_chain` with the digest list; otherwise fall back to `_install_template_from_layers`. The dispatch falls back gracefully if the caller didn't pass digests (e.g. older internal callers): chain mode silently degrades to single-merge.

```bash
zfs::docker_install_from_layers() {
    local -r cache_key="$1" layer_count="$2" unpriv="$3" name="$4"
    shift 4
    local template
    if zfs::layer_chain_active && [ "$#" -ge 1 ]; then
        template=$(zfs::_install_layer_chain "${cache_key}" "${layer_count}" "${unpriv}" "$@")
    else
        template=$(zfs::_install_template_from_layers "${cache_key}" "${layer_count}" "${unpriv}")
    fi
    zfs::clone_container "${template}" "${name}"
}
```

- [ ] **Step 5.2: Pass layer digests from `docker::load`**

In `src/docker.sh` `docker::load`'s ZFS branch (the `if zfs::enabled` block currently calling `zfs::docker_install_from_layers "${config}" "${layer_count}" "${unpriv}" "${name}"`), read the sidecar `./.layers` written by `_prepare_layers` and pass the digests through under chain mode:

```bash
if zfs::enabled; then
    if zfs::layer_chain_active; then
        local layer_digests=()
        readarray -t layer_digests < .layers
        zfs::docker_install_from_layers "${config}" "${layer_count}" "${unpriv}" "${name}" "${layer_digests[@]}"
    else
        zfs::docker_install_from_layers "${config}" "${layer_count}" "${unpriv}" "${name}"
    fi
else
    # existing dir-backend overlay-mount + tar-pipe …
fi
```

- [ ] **Step 5.3: Pass layer digests from `zfs::_pull_and_install_template`**

In `src/storage_zfs.sh`, the puller already calls `zfs::_install_template_from_layers` directly (it bypasses `docker_install_from_layers` because it doesn't clone — only fills the cache for the pointer-import / eviction-recovery flow). It also runs `_prepare_layers` inside its own `common::mktmpdir`+`chdir` block, so the same `./.layers` sidecar is available. Mirror the dispatch:

```bash
if zfs::layer_chain_active; then
    local layer_digests=()
    readarray -t layer_digests < .layers
    zfs::_install_layer_chain "${config}" "${layer_count}" "${unpriv}" "${layer_digests[@]}" > /dev/null
else
    zfs::_install_template_from_layers "${config}" "${layer_count}" "${unpriv}" > /dev/null
fi
```

- [ ] **Step 5.4: Commit**

```sh
git add src/storage_zfs.sh src/docker.sh
git commit -s -m "storage_zfs: dispatch chain mode in docker_install_from_layers and pull path"
```

---

### Task 6: Verify on smoke-test cluster

The compute nodes already share `/var/lib/enroot` over a delegated ZFS pool. Build a `.deb` locally, push to `spark-f2ff`, run the smoke checks below, then revert per CLAUDE.md.

- [ ] **Step 6.1: Single-layer alpine, chain mode**

```sh
sudo systemd-run --user --pty --setenv=ENROOT_ZFS_LAYER_CHAIN=y \
    enroot import -o /tmp/a.sqsh docker://alpine
sudo enroot create -n a /tmp/a.sqsh
sudo enroot start a cat /etc/os-release | head -1
sudo zfs list -r tank/enroot/data/.layers   # should show one layer dataset
sudo enroot remove -f a; rm -f /tmp/a.sqsh
```

Expected: load + start succeed; `.layers/` shows one dataset with the layer's digest.

- [ ] **Step 6.2: Multi-layer debian, whiteouts**

```sh
sudo ENROOT_ZFS_LAYER_CHAIN=y enroot import -o /tmp/d.sqsh docker://debian:stable-slim
sudo enroot create -n d /tmp/d.sqsh
sudo enroot start d cat /etc/os-release | grep PRETTY
sudo find /var/lib/enroot/d -name '.wh.*' | head -3   # must be empty
sudo enroot remove -f d; rm -f /tmp/d.sqsh
```

Expected: container starts; no AUFS whiteouts leak through (the conversion is intact); chain has multiple layer datasets.

- [ ] **Step 6.3: Cross-image base-layer dedup**

```sh
sudo ENROOT_ZFS_LAYER_CHAIN=y enroot import -o /tmp/p.sqsh docker://python:3.12-slim
sudo ENROOT_ZFS_LAYER_CHAIN=y enroot import -o /tmp/n.sqsh docker://node:20-slim
sudo zfs list -r tank/enroot/data/.layers -o name,used,referenced
```

Expected: the base bookworm layer appears once; `python:3-slim` and `node:20-slim` chains share that dataset (visible in `zfs list -t all` as multiple clones of the same `<base>@done`). Block-level sharing visible via `referenced` ≫ `used` on the shared dataset.

- [ ] **Step 6.4: Plan F regression — flag unset**

```sh
sudo enroot import -o /tmp/u.sqsh docker://ubuntu:24.04   # ENROOT_ZFS_LAYER_CHAIN unset
sudo enroot create -n u /tmp/u.sqsh
sudo zfs list -r tank/enroot/data/.layers   # must NOT have created new datasets here
sudo enroot remove -f u; rm -f /tmp/u.sqsh
```

Expected: Plan F's single-merge behavior; `.layers/` either doesn't exist or is unchanged from prior chain-mode runs.

- [ ] **Step 6.5: Pyxis end-to-end with chain mode**

```sh
ssh spark-f2ff 'sudo zfs destroy -r tank/enroot/data/.layers 2>/dev/null || :; \
                sudo zfs destroy -r tank/enroot/data/.templates 2>/dev/null || :'
ENROOT_ZFS_LAYER_CHAIN=y srun -N1 -w spark-f2ff --container-image=docker://debian:stable-slim cat /etc/os-release
ENROOT_ZFS_LAYER_CHAIN=y srun -N1 -w spark-f2ff --container-image=docker://debian:stable-slim hostname
```

Expected: first invocation pays the layer-extract cost once; second is sub-second (template-cache hit).

---

### Task 7: Documentation and PR

**Files:**
- Modify: `doc/zfs.md` — add an `ENROOT_ZFS_LAYER_CHAIN` section under tunables; flip status note to mention Plan G.
- Modify: `CLAUDE.md` — update active-design-proposals line.

- [ ] **Step 7.1: Document and commit**

```sh
git add doc/zfs.md CLAUDE.md
git commit -s -m "Mark Plan G (per-layer ZFS clone chain) as implemented"
git push -u origin feature/zfs-g-layer-chain
gh pr create --repo zeroae/enroot --base zenroot/main --head feature/zfs-g-layer-chain \
    --title "Plan G: per-layer ZFS clone chain for enroot load docker:// (opt-in)" \
    --body "Closes #4."
```

---

## Self-review checklist

- [ ] Default-off: `ENROOT_ZFS_LAYER_CHAIN=` (unset/empty) leaves Plan F's `_install_template_from_layers` path unchanged. Verified at T6.4.
- [ ] Final template shape matches Plan F's (`<store>/.templates/<cfg_sha>@pristine`, readonly, metadata-stamped), so `zfs::clone_container`, pointer-format import, eviction recovery, `enroot export`, and `enroot import zfs://` all keep working.
- [ ] Chain installer covers both load (T5.2) and pull (T5.3) entry points, so chain mode applies to direct `enroot create docker://` AND to the pointer-import / eviction-recovery paths from #13/#14.
- [ ] Whiteouts and opaque dirs handled (T3 phases 1+2). `enroot-aufs2ovlfs`'s overlayfs output is the input to phase 1/2, so AUFS edge cases that aufs2ovlfs already rejects (`.wh..wh.foo`) stay rejected.
- [ ] Race-safe per-layer via `<digest>.tmp` lock (T4). Concurrent imports of different images sharing a layer collapse onto the same dataset; loser waits for `@done`.
- [ ] ENOSPC retry mirrors Plan B's pattern (T4): sweep warm templates, retry once, abort with `.tmp` cleanup on second failure.
- [ ] Layer datasets are immortal until manually swept; ZFS refuses `zfs destroy <layer>` while any descendant clone exists, so layers are GC-protected for free as long as any template references them.

## Known limitations

- **No automated `.layers/` GC.** When the last template referencing a base layer is evicted, the layer dataset survives. ZFS will refuse to destroy it while clones exist; once it's standalone, an admin can `zfs destroy <layer>` manually. A follow-up plan can extend Plan B's `eviction_candidates` to layers (same shape: layer is evictable iff it has no clones).
- **No promote.** Layer datasets are clones-of-clones; the deepest leaf chain has N+1 levels of indirection. ZFS handles this fine performance-wise (snapshots are flat at the block layer), but `zfs list -t all` shows the chain.
- **No cross-host layer replication.** `zfs send` per-layer would be a sensible follow-up but is out of scope here.
- **No migration tool** between Plan F single-merge and Plan G chain caches. Switching the flag mid-life is transparent to users (existing templates remain valid) but the on-disk shape diverges.
- **Whiteout-replay is shell.** `getfattr -R` + `find -type c` + `tar`. Slower than the kernel's overlay engine (which Plan F uses) on a per-layer basis, but the work scales with layer size, not image count, and is paid once per unique layer across all images that use it.

## Out of scope

- Replacing Plan F's single-merge path. Plan G is purely additive.
- Cross-host layer replication via `zfs send`.
- Migration tooling between merged-template and per-layer-chain caches.
- Automated layer-dataset GC (manual `zfs destroy` works today).
- **Chain mode for `dockerd://` / `podman://` URIs.** Daemon-URI imports use `${engine} export | tar -x` which flattens the layered image into a single tarball before extraction — there is no per-layer directory structure for the chain installer to consume. Adding chain support here would require:
  1. Switching the daemon path from `${engine} export` to `${engine} save` (which writes a tar archive containing one `<digest>/layer.tar` per layer plus a `manifest.json` describing the order).
  2. Parsing `manifest.json` to recover the layer-digest list.
  3. Extracting each layer tarball into a directory parallel to what `docker::_prepare_layers` produces, then dispatching to `_install_layer_chain`.
  4. Constructing a synthetic `0/` from the daemon's image config (`${engine} inspect`'s output).
  This is a real follow-up plan, not a one-line addition. It also slightly changes the daemon contract — `docker save` requires more disk (full image tar before extraction) than `docker export` (streamed). For now `ENROOT_ZFS_LAYER_CHAIN=y` is a documented no-op for daemon URIs.

## Execution Handoff

Same options as Plan A.
