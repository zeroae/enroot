# ZFS Backend Plan H: Per-layer Chain for Daemon URIs (`dockerd://`, `podman://`)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend Plan G's per-layer ZFS clone chain (`ENROOT_ZFS_LAYER_CHAIN=y`) to `dockerd://` and `podman://` URIs so daemon-local images get the same cross-image base-layer dedup that registry-pulled `docker://` images get today. Preserves Plan G's default-off behavior — when the flag is unset (or set to anything but `y`), daemon imports continue to use the existing `${engine} export | tar -x` flat path unchanged.

**Why:** Plan G's reuse story ("a debian-bookworm base used by both `python:slim` and `node:slim` is stored once") only kicks in for `docker://`. Sites that build images locally (CI runners, devboxes) and import via `dockerd://` / `podman://` see no on-disk dedup — every image gets its own full template even when 80% of the rootfs is shared with another local image. For HPC clusters with engine-local image registries this matters as much as the registry case.

## Architecture

The daemon-URI flat-export path (`zfs::_extract_and_install_from_daemon` in Plan F's daemon-pointer follow-up) uses:

```
${engine} create --name <ct> <image>
${engine} export <ct> | tar -x -C rootfs/    # flattens; no per-layer information survives
```

`docker export` (and `podman export`) is a *flatten* operation — the daemon walks the layered overlay and produces a single rootfs tarball. We can't recover the layer structure from that output.

`docker save` (and `podman save`) is a *layer-preserving* operation. Its output is a tar archive containing:

```
manifest.json                    # Docker Image Format v1.2 — describes layer order
<config-sha256>.json             # the image config blob
<layer-id-1>/                    # one dir per layer
    layer.tar                    # the layer's content as an uncompressed tar
    json
    VERSION
<layer-id-2>/
    ...
repositories                     # legacy index (ignored)
```

Inside `manifest.json`:
```json
[{
  "Config": "<config-sha>.json",
  "RepoTags": ["myimage:tag"],
  "Layers": [
    "<layer-id-1>/layer.tar",   // BASE first
    "<layer-id-2>/layer.tar",
    ...                          // TOP last
  ]
}]
```

Plan H's daemon-chain installer:

1. `${engine} save <image>` to a streaming pipe (no temp tar archive on disk; pipe straight into `tar -x` at a temp dir).
2. Parse `manifest.json` from the extracted tree → `config` blob path + ordered `Layers` list.
3. For each `<layer-id>/layer.tar`:
   - `sha256sum layer.tar` → cache key for `<store>/.layers/<sha>`.
   - Extract the tarball into directory `i/` (1-based, BASE = 1, TOP = N) — same convention `docker::_prepare_layers` uses for the registry path.
   - Run `enroot-aufs2ovlfs i/` to convert AUFS whiteouts to overlayfs form.
4. Build the synthetic config layer `0/` from the parsed `<config-sha>.json` (or equivalently `${engine} inspect`) using `docker::configure` — identical to the registry path.
5. Call `zfs::_install_layer_chain "${cache_key}" "${layer_count}" "${unpriv}" "${digests[@]}"`.

The cache key (`cache_key`) stays the image-config-sha256 (same as today's daemon path) so a daemon image and the same image pulled via `docker://` *can* share a template if their config shas happen to match. They won't share `.layers/` datasets across sources because `sha256(save-layer.tar)` ≠ `sha256(registry-blob)` (the registry blob is compressed; `docker save` emits uncompressed tarballs); but within the daemon path, multiple local images with shared base layers will dedup at the `.layers/` level.

### Coexistence

- **Flag off (`ENROOT_ZFS_LAYER_CHAIN=` unset/empty):** existing flat `${engine} export | tar -x → _install_template_from_dir` path runs unchanged. Default behavior preserved byte-for-byte.
- **Flag on, daemon URI:** Plan H's `_save_and_install_from_daemon` path runs. Higher peak disk (`docker save` writes a tarball pipe; the per-layer extraction needs ~2× the merged image size at peak vs. flat-export's 1×) but cheaper on subsequent imports of images with shared layers.
- **Flag on, `docker://` URI:** Plan G runs unchanged (this plan does not touch the registry path).
- **Fast path:** the existing "template `@pristine` already exists, reuse it" check runs *before* the chain dispatch, so a daemon image whose config-sha is already cached (from any earlier import via any source) skips the save entirely.

## Files

- **Modify:** `src/storage_zfs.sh` — add `zfs::_save_and_install_from_daemon` (chain-mode counterpart of `_extract_and_install_from_daemon`), wire chain-mode dispatch into `import_daemon_pointer` and `create_from_pointer`'s daemon recovery branch.
- **Modify:** `doc/zfs.md`, `CLAUDE.md` — flip the `ENROOT_ZFS_LAYER_CHAIN` knob description to drop the "docker:// only" caveat.

`docker.sh`, `runtime.sh`, the existing flat-export daemon path, Plan G's helpers (`_apply_layer_payload`, `_build_layer`, `_install_layer_chain`), and `clone_container` are **not** modified.

**Depends on:** Plans A, B, F (daemon pointer follow-up), G.

**Prerequisite host setup:** Same as Plan G plus `${engine} save` permission. Docker Desktop and rootless podman both support `save`. Smoke target: spark-ctrl (Pi 5, OpenZFS 2.4.1, 3.75G test pool) with a docker daemon installed.

---

### Task 1: Add `zfs::_save_and_install_from_daemon`

**Files:**
- Modify: `src/storage_zfs.sh` — append after `_extract_and_install_from_daemon`.

- [ ] **Step 1.1: Add the helper**

Subshell function (parens) so cwd and EXIT trap stay scoped, matching `_extract_and_install_from_daemon`. Inputs match the existing helper (`uri`, `arch`); outputs the resolved image-config-sha256 on stdout (same contract).

```bash
zfs::_save_and_install_from_daemon() (
    local -r uri="$1" arch="$2"
    local image= tmpdir= engine= cache_key= unpriv= image_id=
    local config_blob= layer_count= i=
    local -a layer_paths=() digests=()

    set -euo pipefail

    case "${uri}" in
        dockerd://*) engine="docker" ;;
        podman://*)  engine="podman" ;;
        *)           common::err "_save_and_install_from_daemon: not a daemon URI: ${uri}" ;;
    esac

    common::checkcmd jq sha256sum "${engine}" tar

    local -r reg_image="[[:alnum:]/._:-]+"
    if [[ "${uri}" =~ ^[[:alpha:]]+://(${reg_image})$ ]]; then
        image="${BASH_REMATCH[1]}"
    else
        common::err "Invalid image reference: ${uri}"
    fi

    image_id=$("${engine}" inspect --format '{{.Id}}' "${image}") \
      || common::err "${engine} inspect ${image} failed"
    [[ "${image_id}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || common::err "${engine} returned unexpected image ID: ${image_id}"
    cache_key="${image_id#sha256:}"

    trap 'common::rmall "${tmpdir}" 2> /dev/null' EXIT
    tmpdir=$(common::mktmpdir enroot)
    common::chdir "${tmpdir}"

    common::log INFO "Saving ${engine} image and extracting layers..." NL
    "${engine}" save "${image}" | tar -x

    [ -f manifest.json ] \
      || common::err "${engine} save did not produce manifest.json (unsupported image format?)"

    # manifest.json shape: [{"Config": "...", "Layers": ["<id>/layer.tar", ...]}]
    config_blob=$(common::jq -r '.[0].Config' manifest.json)
    [ -n "${config_blob}" ] && [ -f "${config_blob}" ] \
      || common::err "manifest.json missing Config blob: ${config_blob}"

    readarray -t layer_paths < <(common::jq -r '.[0].Layers[]' manifest.json)
    layer_count="${#layer_paths[@]}"
    [ "${layer_count}" -gt 0 ] \
      || common::err "manifest.json declares no Layers"

    # Per-layer extraction: dir 1/ = layer_paths[0] = BASE (manifest.json
    # ordering puts BASE first, TOP last — opposite of docker::_download's
    # reversed convention). Compute digests as sha256 of each layer.tar so
    # cache keys are content-addressed regardless of the engine's
    # internal layer-id format (legacy v1 uses random IDs; newer formats
    # use content addresses).
    common::log INFO "Computing layer digests and extracting..."
    digests=()
    for ((i=0; i<layer_count; i++)); do
        local lp="${layer_paths[i]}"
        local sha
        sha=$(sha256sum "${lp}" | awk '{print $1}')
        digests+=("${sha}")
        mkdir "$((i+1))"
        tar -C "$((i+1))" --warning=no-timestamp --anchored \
            --exclude='dev/*' --exclude='./dev/*' \
            -pxf "${lp}"
    done
    common::fixperms .

    # Whiteout conversion — same as docker::_prepare_layers does for the
    # registry path. ENROOT_SET_USER_XATTRS=y so opaque dirs get both
    # trusted.overlay.opaque (kernel-readable in userns) and
    # user.overlay.opaque (rootless-friendly).
    common::log INFO "Converting whiteouts..."
    for ((i=1; i<=layer_count; i++)); do
        ENROOT_SET_USER_XATTRS=y enroot-aufs2ovlfs "${i}"
    done

    # Synthetic 0/ — same as the registry path's
    # docker::_prepare_layers final step.
    mkdir 0
    "${engine}" inspect "${image}" \
      | common::jq '.[] | with_entries(.key|=ascii_downcase)' > config
    docker::configure "${PWD}/0" config "${arch}"

    if [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    # Plan G's chain installer expects digests in "TOP first, BASE last"
    # ordering (the reversed convention of docker::_download). Reverse
    # ours to match. _install_layer_chain iterates N-1 down to 0 to
    # build BASE-first on disk, so the on-disk leaf is digests[0] = TOP.
    local -a digests_reversed=()
    for ((i=layer_count-1; i>=0; i--)); do
        digests_reversed+=("${digests[i]}")
    done

    # Wait — directory numbering must match the digest at the same chain
    # position. Plan G's _build_layer takes (digest, prev_layer, layer_dir).
    # With our reversed digests array (digests_reversed[0]=TOP=layer_count,
    # digests_reversed[N-1]=BASE=1), we need layer_dir to follow the
    # same reversal so digests_reversed[k] always lines up with the
    # directory whose tarball produced that digest.
    #
    # Easier: rename our extracted directories to match the registry
    # path's "dir 1 = TOP" convention. Walk i=1..N (currently 1=BASE),
    # rename "i/" to "tmp_i/" and then "tmp_i/" to "(N-i+1)/". One pass.
    for ((i=1; i<=layer_count; i++)); do
        mv "${i}" "tmp_${i}"
    done
    for ((i=1; i<=layer_count; i++)); do
        mv "tmp_${i}" "$((layer_count - i + 1))"
    done

    zfs::_install_layer_chain "${cache_key}" "${layer_count}" "${unpriv}" "${digests_reversed[@]}" > /dev/null

    printf "%s" "${cache_key}"
)
```

- [ ] **Step 1.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add _save_and_install_from_daemon for chain-mode daemon imports"
```

---

### Task 2: Wire chain-mode dispatch in `import_daemon_pointer` and `create_from_pointer`

Two daemon entry points: the initial import (`import_daemon_pointer`) and the eviction-recovery re-pull inside `create_from_pointer`. Both today call `_extract_and_install_from_daemon`. Add a single dispatch in each based on `zfs::layer_chain_active`.

**Files:**
- Modify: `src/storage_zfs.sh`

- [ ] **Step 2.1: `import_daemon_pointer` dispatch**

Before:

```bash
cache_key=$(zfs::_extract_and_install_from_daemon "${uri}" "${arch}")
```

After:

```bash
if zfs::layer_chain_active; then
    cache_key=$(zfs::_save_and_install_from_daemon "${uri}" "${arch}")
else
    cache_key=$(zfs::_extract_and_install_from_daemon "${uri}" "${arch}")
fi
```

- [ ] **Step 2.2: `create_from_pointer` daemon-recovery dispatch**

Replace the existing `dockerd://*|podman://*)` arm in the recovery `case`:

```bash
dockerd://*|podman://*)
    if zfs::layer_chain_active; then
        fresh_config_sha=$(zfs::_save_and_install_from_daemon "${uri}" "${arch}")
    else
        fresh_config_sha=$(zfs::_extract_and_install_from_daemon "${uri}" "${arch}")
    fi
    ;;
```

- [ ] **Step 2.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: dispatch chain mode in daemon-pointer import and recovery"
```

---

### Task 3: Verify on smoke cluster

Spark-ctrl as today (Plan G's smoke target), with a docker daemon installed locally (or use the existing daemon if present). The DGX Spark compute nodes also work but pool space is larger.

- [ ] **Step 3.1: Single-image daemon import, chain mode**

```sh
sudo docker pull alpine:3.21
sudo bash -c 'ENROOT_ZFS_LAYER_CHAIN=y enroot import -o /tmp/a.sqsh dockerd://alpine:3.21'
sudo bash -c 'ENROOT_ZFS_LAYER_CHAIN=y enroot create -n a /tmp/a.sqsh'
sudo zfs list -r tank/enroot/data
sudo cat /var/lib/enroot/a/etc/os-release | head -3
```

Expected: `.layers/<sha>` dataset(s) created (one per layer in the saved image), `.templates/<config-sha>` exists, rootfs has alpine os-release + synthetic `0/` files.

- [ ] **Step 3.2: Cross-image base-layer dedup, daemon path**

```sh
sudo docker pull python:3.13-alpine3.21
sudo docker pull node:22-alpine3.21
for img in python:3.13-alpine3.21 node:22-alpine3.21; do
    sudo bash -c "ENROOT_ZFS_LAYER_CHAIN=y enroot import -o /tmp/${img%%:*}.sqsh dockerd://${img}"
    sudo bash -c "ENROOT_ZFS_LAYER_CHAIN=y enroot create -n ${img%%:*} /tmp/${img%%:*}.sqsh"
done
sudo zfs list -r -d 1 -o name,origin tank/enroot/data/.layers
```

Expected: alpine 3.21 base layer dataset exists once and is the origin of TWO chains (one from python, one from node), same Y-shape as Plan G's `docker://` smoke.

- [ ] **Step 3.3: Plan G regression — `docker://` still works in chain mode**

```sh
sudo bash -c 'ENROOT_ZFS_LAYER_CHAIN=y enroot import -o /tmp/r.sqsh docker://redis:alpine3.21'
sudo bash -c 'ENROOT_ZFS_LAYER_CHAIN=y enroot create -n r /tmp/r.sqsh'
```

Expected: works as before. `_pull_and_install_template` still uses `_install_layer_chain`. No regression.

- [ ] **Step 3.4: Flat-export regression — daemon path with flag unset**

```sh
sudo enroot remove -f a python node r
sudo zfs list -H -o name -r tank/enroot/data | tail -n +2 | tac | xargs -r -n1 sudo zfs destroy -r
sudo bash -c 'enroot import -o /tmp/a.sqsh dockerd://alpine:3.21'
sudo zfs list -r tank/enroot/data    # NO .layers/ dataset expected
sudo bash -c 'enroot create -n a /tmp/a.sqsh'
```

Expected: no `.layers/` namespace; `_install_template_from_dir` populates `.templates/<config-sha>` directly, identical to today's flat-export behavior.

- [ ] **Step 3.5: Eviction recovery via daemon-chain re-save**

```sh
# Create + then destroy template, keep layer-cache
sudo bash -c 'ENROOT_ZFS_LAYER_CHAIN=y enroot import -o /tmp/a.sqsh dockerd://alpine:3.21'
sudo bash -c 'ENROOT_ZFS_LAYER_CHAIN=y enroot create -n a /tmp/a.sqsh'
sudo enroot remove -f a
sudo zfs list -H -o name -r tank/enroot/data/.templates | tail -n +2 | xargs -r -n1 sudo zfs destroy -r

# Re-create from the cached pointer file — recovery path triggers _save_and_install
sudo bash -c 'ENROOT_ZFS_LAYER_CHAIN=y enroot create -n a /tmp/a.sqsh'
sudo zfs list -r tank/enroot/data
```

Expected: `Re-pulling from dockerd://alpine:3.21` log line; layer datasets reused (no `Building layer` messages); template re-cloned from chain leaf.

---

### Task 4: Documentation

**Files:**
- Modify: `doc/zfs.md` — drop the "docker:// only" caveat from the `ENROOT_ZFS_LAYER_CHAIN` knob description; mention the disk-pressure tradeoff (`${engine} save` peak disk ~2× flat-export).
- Modify: `CLAUDE.md` — append a note that Plan H is implemented under PR #?? if relevant.
- Modify: `doc/plans/README.md` — add Plan H row, dependency `G`, recommended landing position after G.

- [ ] **Step 4.1: Commit and PR**

```sh
git add doc/zfs.md CLAUDE.md doc/plans/README.md
git commit -s -m "Mark Plan H (per-layer chain for daemon URIs) as implemented"
git push -u origin feature/zfs-h-daemon-chain
gh pr create --repo zeroae/enroot --base zenroot/main --head feature/zfs-h-daemon-chain \
    --title "Plan H: per-layer ZFS clone chain for dockerd:// / podman:// URIs"
```

---

## Self-review checklist

- [ ] Default-off: `ENROOT_ZFS_LAYER_CHAIN=` unset leaves the daemon flat-export path unchanged. T3.4 covers this.
- [ ] No regression on `docker://` chain mode (Plan G). T3.3 covers this.
- [ ] Daemon-cross-image dedup works at the `.layers/` level when local images share base layer content. T3.2 covers this.
- [ ] Eviction recovery re-uses cached layer datasets and only rebuilds the template clone-of-leaf. T3.5 covers this.
- [ ] Layer-digest computation is content-addressed (sha256 of `layer.tar`) so engine-specific layer-id formats (legacy v1 random IDs vs newer content-addressed) don't matter for the cache key.
- [ ] Synthetic `0/` is built from the same `${engine} inspect` output as the existing daemon path, so per-image config (rc/fstab/environment) matches what users get today.

## Known limitations

- **No cross-source dedup with `docker://`.** A layer pulled via `docker://alpine` and the same layer extracted via `dockerd://alpine` produce different `.layers/<digest>` datasets because the registry blob is gzip/zstd-compressed and `docker save`'s `layer.tar` is uncompressed. Same content, different sha256. We could add a "compressed-and-uncompressed sha both stored as user properties" recovery scheme, but it'd be substantial added complexity for a thin slice of cases.
- **`docker save` disk pressure.** Streaming `${engine} save | tar -x` avoids the full saved-tar landing on disk, but the per-layer `tar -xf <id>/layer.tar` step does need each `layer.tar` to be on disk during extraction (it's not a pipe). Peak disk is ~1× the saved-tar size (which is roughly the same as the merged image size, since `docker save` doesn't compress). For very large images (multi-GB ML containers) this matters. Today's flat-export streams in one pass with no intermediate; Plan H trades that for cross-image dedup.
- **Engine compatibility.** Plan H assumes Docker Image Format v1.1+ (`manifest.json` at archive root, `Layers` array as paths to `layer.tar` files). `podman save` defaults to docker format; OCI archive format (`podman save --format oci-archive`) has a different layout and is **not supported**. Document the assumption.
- **Image config sha vs registry config sha.** Daemon-side `${engine} inspect '{{.Id}}'` is the daemon's image-id; for images pulled from a registry it usually matches the registry's image-config-sha256, but for locally-built images (Dockerfile) it's daemon-local. That's the same situation as today's flat-export path.

## Out of scope

- Replacing the flat-export path (Plan H is purely additive; flag unset preserves byte-for-byte behavior).
- Cross-source `.layers/` dedup between `docker://` and `dockerd://`.
- OCI archive format support (`podman save --format oci-archive`).
- Streaming `${engine} save` directly into per-layer extraction without an intermediate tar dump (tar tools don't natively support "extract just this nested archive from a stream" — would require a custom parser).
- Per-layer-aware digest stamping (e.g. `enroot:image-source=daemon|registry` properties to avoid surprising users when the same logical image has two different layer chains depending on import path). Useful diagnostic but not load-bearing.

## Execution Handoff

Same options as Plan A.
