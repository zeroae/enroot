# ZFS Backend Plan F: ZFS Path for `enroot load docker://`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `ENROOT_STORAGE_BACKEND=zfs`, `enroot load docker://...` no longer requires `ENROOT_NATIVE_OVERLAYFS=y`. The merged image is materialized into a ZFS template dataset (cached by image config digest) and the user's container is a `zfs clone` of it. Default `dir` backend behavior is preserved byte-for-byte and still requires `ENROOT_NATIVE_OVERLAYFS=y`.

**Architecture:** `docker::_prepare_layers` already does the heavy lifting — for each layer it `mkdir N`, untars the layer's tarball into directory `N/`, and runs `enroot-aufs2ovlfs N` to convert AUFS-style whiteouts to overlayfs whiteouts. After it returns, the cwd contains directories `0/` (synthetic config layer with `/etc/{rc,fstab,environment}` from `docker::configure`) and `1/` … `N/` (extracted, whiteout-converted layer trees). The dir-backend `docker::load` then runs `enroot-nsenter --user --remap-root` + `mount -t overlay lowerdir=0:1:…:N rootfs` and tar-pipes the merged view into `${name}/`.

The ZFS path reuses that exact merge logic — the only thing that changes is the *destination* of the tar-pipe: instead of writing into a regular directory under `${ENROOT_DATA_PATH}`, we write into the mountpoint of a freshly-created ZFS template dataset, then snapshot `@pristine` and clone for the user. The clone (and its mountpoint resolution) happens **outside** the user namespace because zfs(8) cannot enumerate datasets from inside one (see Plan E for the full background).

To keep `docker.sh` minimally invasive, all ZFS-specific lifecycle logic lives in `src/storage_zfs.sh` behind two helpers; `docker::load` only dispatches.

**Depends on:** Plan A.

**Prerequisite host setup:** Same as Plan A. Test images: `docker://alpine` (single layer, fast), `docker://debian:stable-slim` (multi-layer, exercises whiteouts).

---

## Files

- **Modify:** `src/storage_zfs.sh` — add `zfs::container_check` (early existence-or-destroy gate) and `zfs::docker_install_from_layers` (template lifecycle + overlay merge + clone-for-user).
- **Modify:** `src/docker.sh` (`docker::load`) — relax the `ENROOT_NATIVE_OVERLAYFS=y` precondition when ZFS is enabled; replace the inline existence-check and merge blocks with two-line backend dispatches calling the new helpers.
- **Modify:** `doc/zfs.md` and `CLAUDE.md` — status notes.

`docker::_prepare_layers`, `docker::configure`, and the existing dir-backend overlay path are **not** modified.

---

### Task 1: Add `zfs::container_check`

A small early-exit gate that errors (or destroys with `--force`) if a container of the given name already exists in the ZFS store. Used so `docker::load` can fail fast before downloading layers it would discard.

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 1.1: Add the helper**

Append to `src/storage_zfs.sh`:

```bash
# Errors (or destroys with --force) if a container with this name already exists
# in the ZFS store. Used as an early-exit gate before doing expensive work
# (e.g. downloading Docker layers we'd just throw away).
zfs::container_check() {
    local -r name="$1"
    local target
    target="$(zfs::store_dataset)/${name}"
    if zfs list -H "${target}" > /dev/null 2>&1; then
        if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
            common::err "Container already exists: ${name}"
        fi
        zfs destroy -r "${target}"
    fi
}
```

- [ ] **Step 1.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::container_check early-exit helper"
```

---

### Task 2: Add `zfs::docker_install_from_layers`

The full ZFS template-fill-and-clone lifecycle for the Docker case. Designed to be called from `docker::load` *after* `docker::_prepare_layers` has populated the cwd with directories `0/`, `1/`, …, `N/`.

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 2.1: Add the helper**

Append to `src/storage_zfs.sh`:

```bash
# Materializes the merged Docker rootfs into a ZFS template (cached by
# cache_key) and clones it as the user's named container. Designed to be
# called from docker::load AFTER docker::_prepare_layers has populated the
# cwd with extracted, whiteout-converted layer directories 0/, 1/, ..., N/.
#
# Inputs:
#   $1 cache_key   - sha256 of the image config blob (a stable per-image key)
#   $2 layer_count - the N from _prepare_layers (count of layer directories)
#   $3 unpriv      - "y" or "" — whether to enter a new user namespace
#   $4 name        - the user-visible container name (no slashes)
#
# Atomicity: races on the same cache_key are resolved via a per-key .tmp
# dataset lock; losers wait for @pristine. ENOSPC mid-merge destroys the
# .tmp so a retry can run.
zfs::docker_install_from_layers() {
    local -r cache_key="$1" layer_count="$2" unpriv="$3" name="$4"
    local store template tmp snap mountpoint i=0
    store=$(zfs::store_dataset)
    template="${store}/${zfs_template_subdir}/${cache_key}"
    tmp="${template}.tmp"
    snap="${template}@${zfs_pristine_snap}"

    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        common::log INFO "Reusing cached template ${cache_key:0:12}"
    elif zfs create -p "${tmp}" 2> /dev/null; then
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        mkdir -p rootfs
        if ! enroot-nsenter ${unpriv:+--user} --mount --remap-root \
                bash -c "mount --make-rprivate / && mount -t overlay overlay -o lowerdir=0:$(seq -s: 1 "${layer_count}") rootfs &&
                         tar --numeric-owner -C rootfs/ --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${mountpoint}/' -xpf -"; then
            zfs destroy -r "${tmp}" 2> /dev/null || :
            common::err "Failed to merge Docker layers into ZFS template"
        fi
        zfs rename "${tmp}" "${template}"
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
    else
        # Lost the race or stale .tmp — wait for @pristine.
        while ! zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; do
            sleep 1
            ((i++ < 600)) || common::err "Timed out waiting for Docker template: ${template}"
        done
    fi

    zfs::clone_container "${template}" "${name}"
}
```

- [ ] **Step 2.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::docker_install_from_layers helper"
```

---

### Task 3: Wire the helpers into `docker::load`

The dir-backend keeps its existing inline path; the ZFS branch is two dispatch calls.

**Files:**
- Modify: `src/docker.sh` (`docker::load`)

- [ ] **Step 3.1: Relax the `ENROOT_NATIVE_OVERLAYFS=y` precondition**

In `src/docker.sh`, change the early precondition check (around line 493):

```bash
    if [ -z "${ENROOT_NATIVE_OVERLAYFS-}" ]; then
        common::err "ENROOT_NATIVE_OVERLAYFS=y is required for enroot load"
    fi
```

to:

```bash
    if ! zfs::enabled && [ -z "${ENROOT_NATIVE_OVERLAYFS-}" ]; then
        common::err "ENROOT_NATIVE_OVERLAYFS=y or ENROOT_STORAGE_BACKEND=zfs is required for enroot load"
    fi
```

- [ ] **Step 3.2: Dispatch the existence check on backend**

Replace the existing-rootfs check (around lines 517–524):

```bash
    name=$(common::realpath "${ENROOT_DATA_PATH}/${name}")
    if [ -e "${name}" ]; then
        if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
            common::err "File already exists: ${name}"
        else
            common::rmall "${name}"
        fi
    fi
```

with:

```bash
    if zfs::enabled; then
        zfs::container_check "${name}"
    else
        name=$(common::realpath "${ENROOT_DATA_PATH}/${name}")
        if [ -e "${name}" ]; then
            if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
                common::err "File already exists: ${name}"
            else
                common::rmall "${name}"
            fi
        fi
    fi
```

- [ ] **Step 3.3: Dispatch the merge step on backend**

Replace the existing merge block (around lines 535–547) — the existing dir-backend `mkdir -p rootfs ... enroot-nsenter ... mount -t overlay ... tar pipe` — with:

```bash
    # Create the final filesystem by overlaying all the layers and copying to target rootfs.
    common::log INFO "Loading container root filesystem..." NL

    # Check if we're running unprivileged.
    if [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    if zfs::enabled; then
        zfs::docker_install_from_layers "${config}" "${layer_count}" "${unpriv}" "${name}"
    else
        # Create a mount namespace and overlay mount
        mkdir -p rootfs "${name}"
        enroot-nsenter ${unpriv:+--user} --mount --remap-root \
                bash -c "mount --make-rprivate / && mount -t overlay overlay -o lowerdir=0:$(seq -s: 1 "${layer_count}") rootfs &&
                         tar --numeric-owner -C rootfs/ --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${name}/' -xpf -"
    fi
```

- [ ] **Step 3.4: Add `unpriv=` to the function's locals**

Near the top of `docker::load`'s local declarations, add `unpriv=` so the variable is initialized before the `if [ "${EUID}" -ne 0 ]` block:

```bash
    local user= registry= image= tag= tmpdir= config= layer_count= unpriv=
```

- [ ] **Step 3.5: Commit**

```sh
git add src/docker.sh
git commit -s -m "Branch docker::load on ENROOT_STORAGE_BACKEND via storage_zfs.sh helpers"
```

---

### Task 4: Verify single-layer image (alpine)

- [ ] **Step 4.1: ZFS load without `ENROOT_NATIVE_OVERLAYFS=y`**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER ENROOT_NATIVE_OVERLAYFS=no \
  /tmp/enroot/usr/bin/enroot load -n alpine_loaded docker://alpine
ls /srv/enroot/$USER/alpine_loaded/etc/os-release
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot start alpine_loaded /bin/cat /etc/os-release | head -2
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot remove -f alpine_loaded
```

Expected: load succeeds; `os-release` readable; `start` prints alpine os-release; `remove` succeeds.

---

### Task 5: Verify multi-layer image with whiteouts (debian:stable-slim)

- [ ] **Step 5.1: Multi-layer load**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER ENROOT_NATIVE_OVERLAYFS=no \
  /tmp/enroot/usr/bin/enroot load -n debian_loaded docker://debian:stable-slim
ls /srv/enroot/$USER/debian_loaded/usr/bin/dpkg && echo "dpkg present"
count=$(sudo find /srv/enroot/$USER/debian_loaded -name '.wh.*' 2>/dev/null | wc -l)
[ "${count}" = "0" ] && echo "no aufs whiteouts OK"
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot start debian_loaded /bin/cat /etc/os-release | grep PRETTY
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot remove -f debian_loaded
```

Expected: load succeeds; `dpkg present`; `no aufs whiteouts OK`; `start` prints Debian os-release.

---

### Task 6: Verify cache reuse and `dir`-backend regression

- [ ] **Step 6.1: Cache reuse on second load**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER ENROOT_NATIVE_OVERLAYFS=no \
  /tmp/enroot/usr/bin/enroot load -n a docker://alpine
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER ENROOT_NATIVE_OVERLAYFS=no \
  bash -c 'time /tmp/enroot/usr/bin/enroot load -n b docker://alpine' 2>&1 | tail -5
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot remove -f a b
```

Expected: second load logs `Reusing cached template ...` and completes in well under a second.

- [ ] **Step 6.2: Dir-backend without `ENROOT_NATIVE_OVERLAYFS=y` errors**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_DATA_PATH=$HOME/.local/share/enroot ENROOT_NATIVE_OVERLAYFS=no \
  /tmp/enroot/usr/bin/enroot load -n a docker://alpine 2>&1 | grep -q 'is required' && echo OK
```

Expected: `OK` — precondition error fires.

- [ ] **Step 6.3: Dir-backend with `ENROOT_NATIVE_OVERLAYFS=y` works (regression)**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_DATA_PATH=$HOME/.local/share/enroot ENROOT_NATIVE_OVERLAYFS=y \
  /tmp/enroot/usr/bin/enroot load -n alpine_dir docker://alpine
ls $HOME/.local/share/enroot/alpine_dir/etc/os-release && echo "dir-backend OK"
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_DATA_PATH=$HOME/.local/share/enroot \
  /tmp/enroot/usr/bin/enroot remove -f alpine_dir
```

Expected: load succeeds; rootfs readable.

---

### Task 7: Document Plan F as implemented and open PR

**Files:**
- Modify: `doc/zfs.md` — flip status note to "Plans A, E, F implemented"; rewrite the `enroot load docker://` row of the "Where the ZFS backend is used" table.
- Modify: `CLAUDE.md` — update the "Active design proposals" line.

- [ ] **Step 7.1: Commit**

```sh
git add doc/zfs.md CLAUDE.md
git commit -s -m "Mark Plan F (Docker load ZFS path) as implemented"
git push -u origin feature/zfs-f-docker-load
gh pr create --repo zeroae/enroot --base zenroot/main --head feature/zfs-f-docker-load \
  --title "Plan F: ZFS path for enroot load docker://" --body "..."
```

---

## Self-review checklist

- [x] Spec coverage: precondition lifted on ZFS (T3.1), early-exit existence check (T1, T3.2), single-pass overlay merge into ZFS clone (T2, T3.3), cache reuse (T6.1), whiteouts handled correctly (T5), dir regression both directions (T6.2, T6.3).
- [x] All ZFS-specific lifecycle logic lives in `src/storage_zfs.sh`; `docker.sh` only dispatches. Helpers used (`zfs::container_check`, `zfs::docker_install_from_layers`) defined in T1, T2 and called in T3.
- [x] No placeholders.

## Known limitations

- **No per-layer dedup across distinct images.** Each distinct image gets its own template at the merged-rootfs level. ZFS `dedup=on` on the templates dataset (admin opt-in) recovers most of this savings via block-level dedup; explicit per-layer-dataset chaining was rejected here in favor of staying close to the existing `_prepare_layers` flow.
- **The merge runs inside `enroot-nsenter --user --remap-root`**, same as the dir backend. The kernel's overlay support (or `fuse-overlayfs` if `ENROOT_NATIVE_OVERLAYFS` is unset) is still the merge engine; we just redirect the tar-pipe target.
- **Concurrent loads of the same image** are race-safe via the same `.tmp` lock pattern as Plan A's `ensure_template`: losers wait for `@pristine`.

## Execution Handoff

Same options as Plan A.
