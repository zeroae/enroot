# ZFS Backend Plan F: ZFS Path for `enroot load docker://`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `ENROOT_STORAGE_BACKEND=zfs`, `enroot load docker://...` stops requiring `ENROOT_NATIVE_OVERLAYFS=y`. Layers are stacked as a chain of ZFS clones (mirroring Docker's own `zfs` storage driver): each layer is `zfs clone parent@done`, the layer tarball is extracted into the clone with whiteout handling, then `zfs snapshot @done`. The leaf snapshot becomes the cached template's `@pristine`, and a clone of that becomes the user's container.

**Architecture:** Add `zfs::stack_layers` that takes the same layer-tarball list `docker::_prepare_layers` produces and replays it onto a fresh chain of ZFS datasets. Modify `docker::load` to dispatch on backend: existing `enroot-mksquashovlfs` path stays for the `dir` backend; ZFS path uses `zfs::stack_layers` and skips the `ENROOT_NATIVE_OVERLAYFS=y` precondition.

**Depends on:** Plan A.

**Prerequisite host setup:** Same as Plan A. Test image: `alpine` from Docker Hub (small, exercises whiteouts via standard Docker tooling).

---

## Files

- **Modify:** `src/storage_zfs.sh` — add `zfs::stack_layers`, `zfs::extract_layer_tarball`.
- **Modify:** `src/docker.sh:488-548` (`docker::load`) — backend dispatch.

---

### Task 1: Add `zfs::extract_layer_tarball` (whiteout-aware)

Docker layer tarballs use AUFS-style whiteouts: `.wh.foo` means "delete `foo` from lower layers"; `.wh..wh..opq` in a directory means "ignore everything from lower layers in this directory." When stacking with overlayfs, the kernel handles these. With ZFS clones, we replicate the semantics manually.

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 1.1: Add the helper**

Append to `src/storage_zfs.sh`:

```bash
# Extracts a single Docker layer tarball into the given mountpoint with
# whiteout/opaque-marker handling, suitable for use on top of a parent layer's
# ZFS clone. Handles both compressed and uncompressed tarballs.
zfs::extract_layer_tarball() {
    local -r tarball="$1" mountpoint="$2"

    common::checkcmd tar awk find

    # Pass 1: extract everything except whiteout markers.
    tar --numeric-owner -C "${mountpoint}" -xpf "${tarball}" \
        --exclude='.wh.*' --exclude='.wh..wh..opq' 2> /dev/null || \
    tar --numeric-owner -C "${mountpoint}" -xpf "${tarball}" \
        --exclude='.wh.*' --exclude='.wh..wh..opq'   # surface real errors on retry

    # Pass 2: list whiteout markers and apply them to the tree.
    tar -tf "${tarball}" 2> /dev/null | awk '
        /\/\.wh\..*$/  { sub(/\.wh\.([^/]+)$/, "\\1"); print "del\t"$0; next }
        /^\.wh\..*$/   { sub(/^\.wh\./, "");           print "del\t"$0; next }
        /\.wh\..wh..opq$/ { sub(/\.wh\..wh..opq$/, ""); print "opq\t"$0; next }
    ' | while IFS=$'\t' read -r kind path; do
        case "${kind}" in
            del)
                rm -rf "${mountpoint}/${path}" 2> /dev/null || :
                ;;
            opq)
                # Opaque dir: clear everything in this directory from lower layers.
                # The directory itself was already created by this layer's pass 1
                # (or already exists from a parent). Remove all children, then let
                # pass 1's content (which we've already laid down) repopulate.
                find "${mountpoint}/${path}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2> /dev/null || :
                # Re-extract the directory's contents from this tar without the wh markers.
                tar --numeric-owner -C "${mountpoint}" -xpf "${tarball}" \
                    --exclude='.wh.*' --exclude='.wh..wh..opq' \
                    "${path}" 2> /dev/null || :
                ;;
        esac
    done
}
```

- [ ] **Step 1.2: Verify with a hand-built tarball**

```sh
mkdir /tmp/wh-test && cd /tmp/wh-test
mkdir -p layer1/usr/bin layer2
echo "old" > layer1/usr/bin/foo
echo "x"   > layer1/keep_me
( cd layer2 && touch usr/bin/.wh.foo )    # delete /usr/bin/foo
tar --numeric-owner -C layer1 -cf l1.tar .
tar --numeric-owner -C layer2 -cf l2.tar .

mkdir target
tar -C target -xpf l1.tar
ls target/usr/bin/foo  # exists

bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         zfs::extract_layer_tarball /tmp/wh-test/l2.tar /tmp/wh-test/target'
ls /tmp/wh-test/target/usr/bin/foo 2>&1 | grep -q "No such" && echo "deleted OK"
ls /tmp/wh-test/target/keep_me && echo "preserved OK"
cd && rm -rf /tmp/wh-test
```

Expected: `deleted OK` and `preserved OK`.

- [ ] **Step 1.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::extract_layer_tarball with whiteout/opaque handling"
```

---

### Task 2: Add `zfs::stack_layers`

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 2.1: Add the function**

Append to `src/storage_zfs.sh`:

```bash
# Stacks an ordered list of Docker layer tarballs as a chain of ZFS datasets.
# Returns the final template's name (an existing template will be reused if its
# leaf snapshot already exists).
#
# Inputs:
#   $1 - cache key (typically sha256 of the manifest digest list, computed by caller)
#   $2 - tab-separated list of layer tarball paths (one per line, in stack order
#        from base to top), passed via stdin
#
# Output (stdout): the template dataset name.
zfs::stack_layers() {
    local -r cache_key="$1"
    local -r store=$(zfs::store_dataset)
    local -r template="${store}/${zfs_template_subdir}/${cache_key}"
    local -r tmp="${template}.tmp"
    local -r snap="${template}@${zfs_pristine_snap}"
    local i timeout=600
    local layers parent layer mountpoint i_layer=0

    zfs::sweep_templates 2> /dev/null || :

    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        zfs::touch_template "${template}" 2> /dev/null || :
        printf "%s" "${template}"
        return
    fi

    # Read layer paths from stdin.
    readarray -t layers

    if zfs create -p "${tmp}" 2> /dev/null; then
        parent="${tmp}"
        for layer in "${layers[@]}"; do
            [ -z "${layer}" ] && continue
            if [ "${i_layer}" -eq 0 ]; then
                # First layer extracts directly into the .tmp dataset.
                mountpoint=$(zfs get -H -o value mountpoint "${parent}")
                common::log INFO "Stacking layer 1/${#layers[@]}..."
                zfs::extract_layer_tarball "${layer}" "${mountpoint}"
                zfs snapshot "${parent}@layer-${i_layer}"
            else
                # Subsequent layers clone the previous snapshot, then extract.
                local child="${tmp}-l${i_layer}"
                zfs clone "${parent}@layer-$((i_layer - 1))" "${child}"
                mountpoint=$(zfs get -H -o value mountpoint "${child}")
                common::log INFO "Stacking layer $((i_layer + 1))/${#layers[@]}..."
                zfs::extract_layer_tarball "${layer}" "${mountpoint}"
                zfs snapshot "${child}@layer-${i_layer}"
                parent="${child}"
            fi
            i_layer=$((i_layer + 1))
        done

        # The 'parent' variable now points at the leaf clone. Promote it so it
        # becomes the new template root, then clean up the intermediate chain.
        if [ "${parent}" != "${tmp}" ]; then
            zfs promote "${parent}"
        fi
        zfs rename "${parent}" "${template}"
        zfs snapshot "${snap}"

        # Best-effort cleanup of intermediate datasets/snapshots.
        local left
        for left in $(zfs list -H -o name -r "${store}/${zfs_template_subdir}" | grep -E "^${tmp//./\\.}(-l[0-9]+)?\$"); do
            zfs destroy -r "${left}" 2> /dev/null || :
        done

        zfs set readonly=on "${template}"
        zfs::touch_template "${template}" 2> /dev/null || :
        printf "%s" "${template}"
        return
    fi

    # Lost the race or stale .tmp — wait for @pristine.
    for ((i = 0; i < timeout; i++)); do
        if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
            printf "%s" "${template}"
            return
        fi
        sleep 1
    done
    common::err "Timed out waiting for layer-stack template: ${template}"
}
```

- [ ] **Step 2.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::stack_layers for Docker layer-stack templates"
```

---

### Task 3: Branch `docker::load` on backend

**Files:**
- Modify: `src/docker.sh:488-548`

- [ ] **Step 3.1: Replace the `ENROOT_NATIVE_OVERLAYFS=y` precondition with a backend-conditional check**

In `src/docker.sh:488-495`, change:

```bash
docker::load() (
    local -r uri="$1"
    local name="$2" arch="$3"
    local user= registry= image= tag= tmpdir= config= layer_count=

    if [ -z "${ENROOT_NATIVE_OVERLAYFS-}" ]; then
        common::err "ENROOT_NATIVE_OVERLAYFS=y is required for enroot load"
    fi
    ...
```

to:

```bash
docker::load() (
    local -r uri="$1"
    local name="$2" arch="$3"
    local user= registry= image= tag= tmpdir= config= layer_count=

    if ! zfs::enabled && [ -z "${ENROOT_NATIVE_OVERLAYFS-}" ]; then
        common::err "ENROOT_NATIVE_OVERLAYFS=y or ENROOT_STORAGE_BACKEND=zfs is required for enroot load"
    fi
    ...
```

- [ ] **Step 3.2: Add backend dispatch for the layer-stacking step**

In `src/docker.sh`, after `docker::_prepare_layers` returns and before the existing `enroot-nsenter ... overlay` block (around line 545), add a backend dispatch.

Locate the existing block (lines 535-547):

```bash
    # Create the final filesystem by overlaying all the layers and copying to target rootfs.
    common::log INFO "Loading container root filesystem..." NL

    # Check if we're running unprivileged.
    if [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    # Create a mount namespace and overlay mount
    mkdir -p rootfs "${name}"
    enroot-nsenter ${unpriv:+--user} --mount --remap-root \
            bash -c "mount --make-rprivate / && mount -t overlay overlay -o lowerdir=0:$(seq -s: 1 "${layer_count}") rootfs &&
                     tar --numeric-owner -C rootfs/ --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${name}/' -xpf -"
)
```

Wrap it in a backend conditional:

```bash
    common::log INFO "Loading container root filesystem..." NL

    if zfs::enabled; then
        # ZFS path: stack layers as a chain of clones; final template, then clone for the user.
        local cache_key template
        # The cache key is the sha256 of the layer-tarball list (stable per-image).
        cache_key=$(printf "%s\n" 0 $(seq 1 "${layer_count}") | xargs -I{} sha256sum {} 2>/dev/null \
                    | awk '{print $1}' | sha256sum | awk '{print $1}')

        # Build the absolute paths to the layer tarballs already prepared in $tmpdir.
        # docker::_prepare_layers leaves layers at "0", "1", ..., "${layer_count}" relative
        # to the cwd at this point. Pass them in stack order (0 first if present, then 1..N).
        local -a layer_paths=()
        [ -e 0 ] && layer_paths+=("$(common::realpath 0)")
        for i in $(seq 1 "${layer_count}"); do
            [ -e "${i}" ] && layer_paths+=("$(common::realpath "${i}")")
        done

        template=$(printf "%s\n" "${layer_paths[@]}" | zfs::stack_layers "${cache_key}")
        zfs::clone_container "${template}" "${name##*/}"
    else
        # Check if we're running unprivileged.
        if [ "${EUID}" -ne 0 ]; then
            unpriv=y
        fi

        # Create a mount namespace and overlay mount
        mkdir -p rootfs "${name}"
        enroot-nsenter ${unpriv:+--user} --mount --remap-root \
                bash -c "mount --make-rprivate / && mount -t overlay overlay -o lowerdir=0:$(seq -s: 1 "${layer_count}") rootfs &&
                         tar --numeric-owner -C rootfs/ --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${name}/' -xpf -"
    fi
)
```

NOTE: `docker::_prepare_layers` writes layer tarballs into the cwd (`$tmpdir`) under integer names; the existing overlay path already references them as `0:$(seq -s: 1 "${layer_count}")`. The exact naming convention (`0`, `1`, …, `N`, with `0` being the empty/lower marker) should be confirmed by reading `docker::_prepare_layers` (`src/docker.sh:306`) before implementing this task. If the naming differs, adjust the layer-paths construction.

- [ ] **Step 3.3: Verify ZFS-backed `enroot load`**

```sh
export ENROOT_STORAGE_BACKEND=zfs
export ENROOT_DATA_PATH=/srv/enroot/$USER
unset ENROOT_NATIVE_OVERLAYFS
/tmp/enroot/usr/bin/enroot load docker://alpine -n alpine_loaded
ls /srv/enroot/$USER/alpine_loaded/etc/os-release
zfs list | grep alpine_loaded
/tmp/enroot/usr/bin/enroot remove -f alpine_loaded
```

Expected: load succeeds without `ENROOT_NATIVE_OVERLAYFS=y`; clone is listed; os-release readable.

- [ ] **Step 3.4: Verify `dir` backend `enroot load` still requires `ENROOT_NATIVE_OVERLAYFS=y` (no regression)**

```sh
unset ENROOT_STORAGE_BACKEND
unset ENROOT_NATIVE_OVERLAYFS
/tmp/enroot/usr/bin/enroot load docker://alpine -n a 2>&1 | grep -q "is required" && echo OK
ENROOT_NATIVE_OVERLAYFS=y /tmp/enroot/usr/bin/enroot load docker://alpine -n a
/tmp/enroot/usr/bin/enroot remove -f a
```

Expected: first invocation errors with the precondition message (`OK`); second succeeds.

- [ ] **Step 3.5: Verify whiteouts work end-to-end**

Use a test image with known whiteouts (any multi-layer image where a later layer deletes a file from an earlier one — `python:3-slim` is a common example):

```sh
export ENROOT_STORAGE_BACKEND=zfs
/tmp/enroot/usr/bin/enroot load docker://python:3-slim -n py
ls /srv/enroot/$USER/py/usr/bin/python3 && echo "ok"
# Check no .wh. files leaked through:
find /srv/enroot/$USER/py -name '.wh.*' | head && echo "BAD" || echo "clean"
/tmp/enroot/usr/bin/enroot remove -f py
```

Expected: `ok` and `clean`.

- [ ] **Step 3.6: Commit**

```sh
git add src/docker.sh
git commit -s -m "Branch docker::load on ENROOT_STORAGE_BACKEND; lift overlay precondition for ZFS"
```

---

### Task 4: Document Plan F as implemented

**Files:**
- Modify: `doc/zfs.md`

- [ ] **Step 4.1: Update status note**

Update `doc/zfs.md` to mark Plan F (Docker layer stacking on ZFS) as landed.

- [ ] **Step 4.2: End-to-end smoke**

```sh
export ENROOT_STORAGE_BACKEND=zfs
unset ENROOT_NATIVE_OVERLAYFS
/tmp/enroot/usr/bin/enroot load docker://alpine -n a
/tmp/enroot/usr/bin/enroot start a /bin/cat /etc/os-release
/tmp/enroot/usr/bin/enroot load docker://alpine -n b   # second time should reuse template
zfs list -t all | grep templates | wc -l               # should be 1, not 2
/tmp/enroot/usr/bin/enroot remove -f a b
```

Expected: both loads succeed; only one template remains.

- [ ] **Step 4.3: Commit**

```sh
git add doc/zfs.md
git commit -s -m "Mark Plan F (Docker load ZFS path) as implemented"
```

---

## Self-review checklist

- [x] Spec coverage: ZFS layer-stacking instead of mksquashovlfs (T2, T3.2); `ENROOT_NATIVE_OVERLAYFS=y` precondition lifted on ZFS (T3.1, T3.3); whiteout & opaque-dir handling (T1, T3.5); cache reuse across loads of same image (T2 fast-path, T4.2 verifies); `dir` backend behavior unchanged (T3.4 regression check).
- [x] Type consistency: `zfs::extract_layer_tarball`, `zfs::stack_layers` defined in T1, T2; both used in T3.
- [x] No placeholders.

## Known limitations & open questions

- **Step 3.2 has an explicit caveat** about `docker::_prepare_layers`'s on-disk naming. The implementer must read `src/docker.sh:306-330` and confirm before writing the layer-paths array. If `_prepare_layers` writes to a different layout, the array construction must be adjusted accordingly.
- **`zfs promote` on the leaf** is the canonical way to "flatten" a clone chain into a standalone dataset. We do this so the intermediate `-l1`, `-l2`, … datasets can be destroyed and the cache stores only the final template. If `zfs promote` is unavailable for the user's delegations, an alternative is to keep the chain alive and accept extra dataset objects (no functional impact, just `zfs list` clutter).
- **Per-layer xattr handling** (capability bits, immutable flags, security.* attrs) is the same as Docker's own `zfs` driver — `tar --numeric-owner` plus the `xattr=sa` filesystem property carries them. Note in `doc/zfs.md` admin recipe (already covered there as a default).
- **Concurrent `enroot load` of the same image** is race-safe via the same `.tmp` lock as Plan A's `ensure_template` — losers wait for `@pristine`.
- **Sparse files in layers** are not specially handled; tar's default sparse handling applies. Likely fine for v1.

## Execution Handoff

Same options as Plan A.
