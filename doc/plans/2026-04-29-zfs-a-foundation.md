# ZFS Backend Plan A: Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `ENROOT_STORAGE_BACKEND=zfs` storage driver that replaces `unsquashfs`-per-create with `zfs clone`-per-create, plus a fast `enroot remove` that destroys the dataset (and its template if it has no other clones). Default `dir` backend behavior is preserved byte-for-byte.

**Architecture:** Add a new sourced module `src/storage_zfs.sh` containing all ZFS-specific helpers under a `zfs::` namespace. Branch on `${ENROOT_STORAGE_BACKEND}` in `runtime::create` and `runtime::remove`. Templates live at `${ENROOT_DATA_PATH}/.templates/<sha256>` with snapshot `@pristine`; user clones live at `${ENROOT_DATA_PATH}/<NAME>`. ZFS pool/dataset is admin-provisioned at `${ENROOT_DATA_PATH}` mountpoint.

**Tech Stack:** Bash >= 4.2, OpenZFS, sha256sum, unsquashfs (existing). No new C code, no new build dependencies.

**Project conventions:** No automated tests; verification is manual. Functions are namespaced with `::` (`zfs::ensure_template`). Bash uses `set -euo pipefail; shopt -s lastpipe`. Helpers live in `src/*.sh` and are `source`d, never executed.

**Prerequisite host setup for testing:**

```sh
sudo zpool create -f tank /dev/loop0          # or any test device
sudo zfs create -o mountpoint=/srv/enroot tank/enroot
sudo zfs allow $USER create,mount,clone,destroy,snapshot,rename,readonly tank/enroot
mkdir -p ~/.config/enroot
echo 'ENROOT_DATA_PATH /srv/enroot/'$USER >> ~/.config/enroot/.enroot.conf
echo 'ENROOT_STORAGE_BACKEND zfs' >> ~/.config/enroot/.enroot.conf
zfs create tank/enroot/$USER
```

A scratch test image: `enroot import docker://alpine` produces `alpine.sqsh` for use throughout verification.

---

## Files

- **Create:** `src/storage_zfs.sh` — ZFS storage driver (~150 lines).
- **Modify:** `enroot.in:96` — add `ENROOT_STORAGE_BACKEND` config export.
- **Modify:** `enroot.in:114` — source `storage_zfs.sh` after `runtime.sh`.
- **Modify:** `src/runtime.sh:391-430` — branch `runtime::create` on backend.
- **Modify:** `src/runtime.sh:598-620` — branch `runtime::remove` on backend.
- **Modify:** `conf/enroot.conf.in` — add commented `#ENROOT_STORAGE_BACKEND dir` line.
- **Modify:** `Makefile` — add `src/storage_zfs.sh` to `SRCS`.

---

### Task 1: Wire `ENROOT_STORAGE_BACKEND` config knob

**Files:**
- Modify: `enroot.in:96-103` (config exports section)
- Modify: `conf/enroot.conf.in:21` (after the `ENROOT_NATIVE_OVERLAYFS` block)

- [ ] **Step 1.1: Add config export to `enroot.in`**

In `enroot.in`, find the block ending around line 100 (`config::export ENROOT_FORCE_OVERRIDE   false`). Add immediately after it:

```bash
config::export ENROOT_STORAGE_BACKEND  "dir"
```

Place it before `config::fini` on line 104.

- [ ] **Step 1.2: Add config doc line to `conf/enroot.conf.in`**

After line 22 (the `ENROOT_NATIVE_OVERLAYFS` block), insert:

```
# Storage backend for the container store. "dir" = today's plain directories (default).
# "zfs" = use ZFS datasets; ENROOT_DATA_PATH must be a ZFS dataset mountpoint with
# create/mount/clone/destroy/snapshot delegations granted to the user. See doc/zfs.md.
#ENROOT_STORAGE_BACKEND     dir
```

- [ ] **Step 1.3: Verify the config knob plumbs through**

Run:

```sh
make
ENROOT_STORAGE_BACKEND=zfs ./enroot info | grep STORAGE
```

Expected: a line like `ENROOT_STORAGE_BACKEND=zfs` in the output. If it shows `dir`, the config::export call did not land.

- [ ] **Step 1.4: Commit**

```sh
git add enroot.in conf/enroot.conf.in
git commit -s -m "Add ENROOT_STORAGE_BACKEND config knob"
```

---

### Task 2: Create `src/storage_zfs.sh` skeleton

**Files:**
- Create: `src/storage_zfs.sh`
- Modify: `enroot.in:114` (source the new file)
- Modify: `Makefile:29-32` (add to SRCS)

- [ ] **Step 2.1: Create the new module with header and a backend predicate**

Write `src/storage_zfs.sh`:

```bash
# Copyright (c) 2018-2026, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

[ -v _STORAGE_ZFS_SH_ ] && return || readonly _STORAGE_ZFS_SH_=1

source "${ENROOT_LIBRARY_PATH}/common.sh"

readonly zfs_template_subdir=".templates"
readonly zfs_pristine_snap="pristine"

# Returns 0 if the ZFS storage backend is configured, 1 otherwise.
zfs::enabled() {
    [ "${ENROOT_STORAGE_BACKEND-dir}" = "zfs" ]
}

# Resolves and prints the ZFS dataset name backing ${ENROOT_DATA_PATH}.
# Errors if the path is not a ZFS dataset mountpoint.
zfs::store_dataset() {
    local dataset
    dataset=$(zfs list -H -o name "${ENROOT_DATA_PATH}" 2> /dev/null) || \
        common::err "ENROOT_DATA_PATH (${ENROOT_DATA_PATH}) is not a ZFS dataset mountpoint"
    printf "%s" "${dataset}"
}

# Errors with a clear message if zfs(8) is unavailable or the store is not on ZFS.
zfs::checkenv() {
    common::checkcmd zfs sha256sum
    zfs::store_dataset > /dev/null
}
```

- [ ] **Step 2.2: Source it from `enroot.in`**

In `enroot.in`, find the block at line 112-114:

```bash
source "${ENROOT_LIBRARY_PATH}/common.sh"
source "${ENROOT_LIBRARY_PATH}/docker.sh"
source "${ENROOT_LIBRARY_PATH}/runtime.sh"
```

Add a fourth line after `runtime.sh`:

```bash
source "${ENROOT_LIBRARY_PATH}/storage_zfs.sh"
```

- [ ] **Step 2.3: Add to `Makefile` `SRCS` so it ships on install**

In `Makefile` at lines 29-32, change `SRCS` to:

```make
SRCS := src/common.sh      \
        src/bundle.sh      \
        src/docker.sh      \
        src/runtime.sh     \
        src/storage_zfs.sh
```

- [ ] **Step 2.4: Verify it builds and sources clean**

```sh
make clean && make
bash -n src/storage_zfs.sh && echo "syntax ok"
ENROOT_STORAGE_BACKEND=zfs ./enroot version
```

Expected: build succeeds; `syntax ok` prints; `enroot version` prints the version string without errors.

- [ ] **Step 2.5: Commit**

```sh
git add src/storage_zfs.sh enroot.in Makefile
git commit -s -m "Scaffold src/storage_zfs.sh module"
```

---

### Task 3: Add image-hashing helper

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 3.1: Add `zfs::image_sha256` function**

Append to `src/storage_zfs.sh`:

```bash
# Computes the sha256 of a squashfs image file. Used as the template cache key.
zfs::image_sha256() {
    local -r image="$1"
    sha256sum "${image}" | awk '{print $1}'
}
```

- [ ] **Step 3.2: Verify it produces stable hashes**

```sh
. ./enroot.in 2>/dev/null  # for source-test purposes only; will exit on bash version check
# Easier:
bash -c 'source src/common.sh; source src/storage_zfs.sh; zfs::image_sha256 alpine.sqsh' || true
sha256sum alpine.sqsh | awk '{print $1}'
```

Expected: both commands print the same 64-character hex string.

- [ ] **Step 3.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::image_sha256 helper"
```

---

### Task 4: Add template-ensure helper (atomic extraction)

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 4.1: Add `zfs::ensure_template`**

Append to `src/storage_zfs.sh`:

```bash
# Ensures a template dataset exists for the given image hash, extracting if needed.
# Prints the template's full dataset name (e.g. tank/enroot/.templates/<sha>).
# Atomic across concurrent callers via a per-hash .tmp dataset.
zfs::ensure_template() {
    local -r image="$1" sha="$2"
    local -r store=$(zfs::store_dataset)
    local -r template="${store}/${zfs_template_subdir}/${sha}"
    local -r tmp="${template}.tmp"
    local -r snap="${template}@${zfs_pristine_snap}"
    local -r mountpoint
    local i timeout=600

    # Fast path: template already exists with @pristine.
    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        printf "%s" "${template}"
        return
    fi

    # Try to create the .tmp dataset atomically. Whoever wins is the extractor.
    if zfs create -p "${tmp}" 2> /dev/null; then
        # We won — extract.
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        common::log INFO "Extracting squashfs filesystem into ZFS template..." NL
        [ $(ulimit -n) -gt $((2**26)) ] && ulimit -n $((2**26))
        unsquashfs ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
                   -user-xattrs -f -d "${mountpoint}" "${image}" >&2
        common::fixperms "${mountpoint}"
        zfs rename "${tmp}" "${template}"
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
        printf "%s" "${template}"
        return
    fi

    # Lost the race or stale .tmp from a crashed extractor. Wait for @pristine.
    for ((i = 0; i < timeout; i++)); do
        if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
            printf "%s" "${template}"
            return
        fi
        sleep 1
    done

    common::err "Timed out waiting for template extraction: ${template}. \
A previous extractor may have crashed; remove ${tmp} manually and retry."
}
```

- [ ] **Step 4.2: Verify with a single extraction**

```sh
make install DESTDIR=/tmp/enroot prefix=/usr
export PATH=/tmp/enroot/usr/bin:$PATH
export ENROOT_LIBRARY_PATH=/tmp/enroot/usr/lib/enroot
export ENROOT_SYSCONF_PATH=/tmp/enroot/usr/etc/enroot
export ENROOT_STORAGE_BACKEND=zfs
export ENROOT_DATA_PATH=/srv/enroot/$USER
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         zfs::ensure_template alpine.sqsh $(sha256sum alpine.sqsh | awk "{print \$1}")'
zfs list -t all | grep templates
```

Expected: a dataset like `tank/enroot/<USER>/.templates/<sha>` and a `@pristine` snapshot listed by `zfs list -t all`.

- [ ] **Step 4.3: Verify race safety with concurrent extractions**

```sh
zfs destroy -r tank/enroot/$USER/.templates 2>/dev/null
for i in 1 2 3 4; do
    bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
             source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
             zfs::ensure_template alpine.sqsh $(sha256sum alpine.sqsh | awk "{print \$1}")' &
done
wait
zfs list -t all | grep templates
```

Expected: exactly one template dataset and one `@pristine` snapshot. No `.tmp` left behind. All four background processes exit 0.

- [ ] **Step 4.4: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::ensure_template with atomic extraction"
```

---

### Task 5: Add clone helper for `create`

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 5.1: Add `zfs::clone_container`**

Append to `src/storage_zfs.sh`:

```bash
# Clones the @pristine snapshot of a template into a named user container.
# Errors if the target name is already taken.
zfs::clone_container() {
    local -r template="$1" name="$2"
    local -r store=$(zfs::store_dataset)
    local -r target="${store}/${name}"

    if zfs list -H "${target}" > /dev/null 2>&1; then
        if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
            common::err "Container already exists: ${name}"
        fi
        zfs destroy -r "${target}"
    fi

    zfs clone "${template}@${zfs_pristine_snap}" "${target}"
}
```

- [ ] **Step 5.2: Verify a clone works end-to-end**

```sh
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         sha=$(sha256sum alpine.sqsh | awk "{print \$1}")
         template=$(zfs::ensure_template alpine.sqsh "${sha}")
         zfs::clone_container "${template}" alpine_test'
zfs list | grep alpine_test
ls /srv/enroot/$USER/alpine_test/etc/os-release
zfs destroy tank/enroot/$USER/alpine_test  # cleanup
```

Expected: clone dataset listed; `os-release` readable; cleanup succeeds.

- [ ] **Step 5.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::clone_container helper"
```

---

### Task 6: Add destroy helper with template refcount

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 6.1: Add `zfs::destroy_container`**

Append to `src/storage_zfs.sh`:

```bash
# Destroys a user container and its template if no other clones reference the
# template's @pristine snapshot. (Refcount-only behavior; warm-period eviction
# is added in plan B.)
zfs::destroy_container() {
    local -r name="$1"
    local -r store=$(zfs::store_dataset)
    local -r target="${store}/${name}"
    local origin

    if ! zfs list -H "${target}" > /dev/null 2>&1; then
        common::err "No such container: ${name}"
    fi

    origin=$(zfs get -H -o value origin "${target}")
    zfs destroy "${target}"

    # Try to destroy the origin's template if no other clones remain.
    # 'zfs destroy' on a snapshot with clones fails harmlessly; we attempt and ignore.
    if [ -n "${origin}" ] && [ "${origin}" != "-" ]; then
        local template="${origin%@*}"
        zfs destroy "${origin}" 2> /dev/null && \
            zfs destroy "${template}" 2> /dev/null || :
    fi
}
```

- [ ] **Step 6.2: Verify single-clone destroy reaps the template**

```sh
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         sha=$(sha256sum alpine.sqsh | awk "{print \$1}")
         template=$(zfs::ensure_template alpine.sqsh "${sha}")
         zfs::clone_container "${template}" only
         zfs::destroy_container only'
zfs list -t all | grep -c templates
```

Expected: `0` (template was reaped because it had no other clones).

- [ ] **Step 6.3: Verify multi-clone destroy keeps the template alive**

```sh
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         sha=$(sha256sum alpine.sqsh | awk "{print \$1}")
         template=$(zfs::ensure_template alpine.sqsh "${sha}")
         zfs::clone_container "${template}" first
         zfs::clone_container "${template}" second
         zfs::destroy_container first'
zfs list -t all | grep -c templates
zfs list | grep second
```

Expected: `1` (template still alive because `second` clone still references it); `second` clone listed. Cleanup: `zfs destroy tank/enroot/$USER/second` (which also reaps the template).

- [ ] **Step 6.4: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::destroy_container with refcount-on-remove"
```

---

### Task 7: Wire ZFS path into `runtime::create`

**Files:**
- Modify: `src/runtime.sh:391-430`

- [ ] **Step 7.1: Add backend dispatch at top of `runtime::create`**

In `src/runtime.sh`, replace the body of `runtime::create` (lines 391-430) with:

```bash
runtime::create() {
    local image="$1" rootfs="$2"

    # Resolve the container image path.
    if [ -z "${image}" ]; then
        common::err "Invalid argument"
    fi
    image=$(common::realpath "${image}")
    if [ ! -f "${image}" ]; then
        common::err "No such file or directory: ${image}"
    fi
    if ! unsquashfs -s "${image}" > /dev/null 2>&1; then
        common::err "Invalid image format: ${image}"
    fi

    # Resolve the container rootfs name.
    if [ -z "${rootfs}" ]; then
        rootfs=$(basename "${image%.sqsh}")
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi

    if zfs::enabled; then
        runtime::_create_zfs "${image}" "${rootfs}"
    else
        runtime::_create_dir "${image}" "${rootfs}"
    fi
}

runtime::_create_dir() {
    local -r image="$1" rootfs_name="$2"
    local rootfs

    common::checkcmd unsquashfs find

    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs_name}")
    if [ -e "${rootfs}" ]; then
        if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
            common::err "File already exists: ${rootfs}"
        else
            common::rmall "${rootfs}"
        fi
    fi

    common::log INFO "Extracting squashfs filesystem..." NL
    [ $(ulimit -n) -gt $((2**26)) ] && ulimit -n $((2**26))
    unsquashfs ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
               -user-xattrs -d "${rootfs}" "${image}" >&2
    common::fixperms "${rootfs}"
}

runtime::_create_zfs() {
    local -r image="$1" rootfs_name="$2"
    local sha template

    zfs::checkenv
    sha=$(zfs::image_sha256 "${image}")
    template=$(zfs::ensure_template "${image}" "${sha}")
    zfs::clone_container "${template}" "${rootfs_name}"
}
```

- [ ] **Step 7.2: Verify the dir backend still works (no regression)**

```sh
unset ENROOT_STORAGE_BACKEND
export ENROOT_DATA_PATH=$HOME/.local/share/enroot
make && make install DESTDIR=/tmp/enroot prefix=/usr
/tmp/enroot/usr/bin/enroot create -n test_dir alpine.sqsh
ls $ENROOT_DATA_PATH/test_dir/etc/os-release
/tmp/enroot/usr/bin/enroot remove -f test_dir
```

Expected: `os-release` exists; remove succeeds. This is today's behavior unchanged.

- [ ] **Step 7.3: Verify the zfs backend creates a clone**

```sh
export ENROOT_STORAGE_BACKEND=zfs
export ENROOT_DATA_PATH=/srv/enroot/$USER
/tmp/enroot/usr/bin/enroot create -n test_zfs alpine.sqsh
zfs list | grep test_zfs
ls /srv/enroot/$USER/test_zfs/etc/os-release
```

Expected: clone dataset listed; `os-release` readable.

- [ ] **Step 7.4: Verify second create from same image is fast (clone, not extract)**

```sh
time /tmp/enroot/usr/bin/enroot create -n test_zfs2 alpine.sqsh
```

Expected: completes in <1s (vs. multi-second for the first create). No "Extracting squashfs filesystem" log line.

- [ ] **Step 7.5: Commit**

```sh
git add src/runtime.sh
git commit -s -m "Branch runtime::create on ENROOT_STORAGE_BACKEND"
```

---

### Task 8: Wire ZFS path into `runtime::remove`

**Files:**
- Modify: `src/runtime.sh:598-620`

- [ ] **Step 8.1: Add backend dispatch in `runtime::remove`**

In `src/runtime.sh`, replace the body of `runtime::remove` (lines 598-620) with:

```bash
runtime::remove() {
    local rootfs_name="$1"

    if [ -z "${rootfs_name}" ]; then
        common::err "Invalid argument"
    fi
    if [[ "${rootfs_name}" == */* ]]; then
        common::err "Invalid argument: ${rootfs_name}"
    fi

    if zfs::enabled; then
        runtime::_remove_zfs "${rootfs_name}"
    else
        runtime::_remove_dir "${rootfs_name}"
    fi
}

runtime::_remove_dir() {
    local -r rootfs_name="$1"
    local rootfs
    rootfs=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs_name}")
    if [ ! -d "${rootfs}" ]; then
        common::err "No such file or directory: ${rootfs}"
    fi
    if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
        read -r -e -p "Do you really want to delete ${rootfs}? [y/N] "
    fi
    if [ -n "${ENROOT_FORCE_OVERRIDE-}" ] || [ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ]; then
        common::rmall "${rootfs}"
    fi
}

runtime::_remove_zfs() {
    local -r rootfs_name="$1"
    local rootfs
    rootfs="${ENROOT_DATA_PATH}/${rootfs_name}"
    if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
        read -r -e -p "Do you really want to delete ${rootfs}? [y/N] "
    fi
    if [ -n "${ENROOT_FORCE_OVERRIDE-}" ] || [ "${REPLY}" = "y" ] || [ "${REPLY}" = "Y" ]; then
        zfs::destroy_container "${rootfs_name}"
    fi
}
```

- [ ] **Step 8.2: Verify remove on the ZFS backend**

```sh
zfs list | grep -E "test_zfs|templates"
/tmp/enroot/usr/bin/enroot remove -f test_zfs
zfs list | grep test_zfs
zfs list | grep templates  # should still exist (test_zfs2 still references it)
/tmp/enroot/usr/bin/enroot remove -f test_zfs2
zfs list | grep -E "test_zfs|templates"  # both gone
```

Expected: first remove takes out only the clone; templates list still has the entry. Second remove takes out both the clone and the template.

- [ ] **Step 8.3: Verify dir backend remove still works**

```sh
unset ENROOT_STORAGE_BACKEND
export ENROOT_DATA_PATH=$HOME/.local/share/enroot
/tmp/enroot/usr/bin/enroot create -n test_dir alpine.sqsh
/tmp/enroot/usr/bin/enroot remove -f test_dir
ls $ENROOT_DATA_PATH/test_dir 2>&1 | grep -q "No such" && echo "ok"
```

Expected: `ok`.

- [ ] **Step 8.4: Commit**

```sh
git add src/runtime.sh
git commit -s -m "Branch runtime::remove on ENROOT_STORAGE_BACKEND with refcount cleanup"
```

---

### Task 9: Verify `runtime::list` and `runtime::start` work transparently

**Files:**
- (Read-only verification — no code changes expected, but confirm.)

- [ ] **Step 9.1: Verify `enroot list` enumerates ZFS clones**

```sh
export ENROOT_STORAGE_BACKEND=zfs
export ENROOT_DATA_PATH=/srv/enroot/$USER
/tmp/enroot/usr/bin/enroot create -n list_a alpine.sqsh
/tmp/enroot/usr/bin/enroot create -n list_b alpine.sqsh
/tmp/enroot/usr/bin/enroot list
```

Expected: `list_a` and `list_b` listed; the `.templates` directory should NOT appear.

If `.templates` appears, fix `runtime::list` to filter dotfiles. The current `ls -1` in `runtime::list:546` does not show dotfiles by default, so this should work without changes — but verify.

- [ ] **Step 9.2: If `.templates` appears in `enroot list`, filter it**

If verification in 9.1 fails, modify `runtime::list` (`src/runtime.sh:545-548`) to filter the templates subdir:

```bash
    if [ -z "${fancy}" ]; then
        ls -1 | grep -v "^\.${zfs_template_subdir##.}\$" || :
        return
    fi
```

(Only apply this if 9.1 actually showed `.templates`. The default `ls -1` already hides dotfiles, so this is a defensive check.)

- [ ] **Step 9.3: Verify `enroot start` against a ZFS clone**

```sh
/tmp/enroot/usr/bin/enroot start list_a /bin/echo hello
```

Expected: prints `hello` and exits 0. The clone is mounted as a regular filesystem, so the existing start path should work without modification.

- [ ] **Step 9.4: Cleanup**

```sh
/tmp/enroot/usr/bin/enroot remove -f list_a list_b
zfs list -t all | grep -E "list_|templates" || echo "clean"
```

Expected: `clean`.

- [ ] **Step 9.5: Commit (only if Step 9.2 changed code)**

```sh
git add src/runtime.sh
git commit -s -m "Filter .templates from enroot list under ZFS backend"
```

---

### Task 10: Document the foundation and tag a checkpoint

**Files:**
- Modify: `doc/zfs.md` (status note)

- [ ] **Step 10.1: Mark Plan A status in `doc/zfs.md`**

In `doc/zfs.md`, replace the line near the top that reads:

```
This document describes an optional ZFS-aware mode for the enroot container store. It is a design proposal — not yet implemented.
```

with:

```
This document describes an optional ZFS-aware mode for the enroot container store. As of release X.Y, the foundation (Plan A) is implemented: `enroot create` and `enroot remove` use ZFS datasets when `ENROOT_STORAGE_BACKEND=zfs`. The remaining substitutions (ephemeral start, Docker layer stacking) and the `.zfs`/`zfs://` transports are tracked in subsequent plans.
```

- [ ] **Step 10.2: End-to-end smoke test**

```sh
export ENROOT_STORAGE_BACKEND=zfs
export ENROOT_DATA_PATH=/srv/enroot/$USER
/tmp/enroot/usr/bin/enroot create -n smoke alpine.sqsh
/tmp/enroot/usr/bin/enroot list | grep smoke
/tmp/enroot/usr/bin/enroot start smoke /bin/cat /etc/os-release
/tmp/enroot/usr/bin/enroot remove -f smoke
zfs list -t all | grep -E "smoke|templates" || echo "clean"
```

Expected: list shows `smoke`; start prints alpine os-release; remove succeeds; final state is clean.

- [ ] **Step 10.3: Commit**

```sh
git add doc/zfs.md
git commit -s -m "Mark Plan A (ZFS foundation) as implemented"
```

---

## Self-review checklist

- [x] Spec coverage: `ENROOT_STORAGE_BACKEND` knob (T1), backend abstraction (T2-7), ZFS create flow (T4-5,7), refcount-on-remove (T6,8), bundle untouched (no task — bundle code already operates on rootfs directories which a clone presents identically), `enroot list` and `enroot start` transparency verified (T9).
- [x] Out of scope, deferred to later plans: warm-period eviction (Plan B), `.zfs` file format (Plan C), `zfs://` URI (Plan D), ephemeral-start ZFS substitution (Plan E), Docker layer-stacking (Plan F).
- [x] No placeholders. Every step has the actual diff or command.
- [x] Type consistency: function names used in T7-8 (`zfs::enabled`, `zfs::checkenv`, `zfs::image_sha256`, `zfs::ensure_template`, `zfs::clone_container`, `zfs::destroy_container`) all match the definitions in T2-6.

## Known limitations of Plan A

These are deliberate and addressed by later plans:

- **No `.zfs` file support.** Only `.sqsh` is accepted by `enroot create`. (Plan C)
- **No `zfs://` URI.** Only file-based images. (Plan D)
- **`enroot start image.sqsh` (ephemeral) still uses squashfuse + overlay** even on the ZFS backend. (Plan E)
- **`enroot load docker://` still requires `ENROOT_NATIVE_OVERLAYFS=y`** even on the ZFS backend. (Plan F)
- **No template warm period.** Templates are reaped immediately when the last clone goes away. CI workflows that create+remove+create the same image pay re-extraction cost. (Plan B)
- **No quota-pressure eviction.** Unbounded template accumulation if WARM_SECONDS were nonzero — moot in Plan A since it's effectively zero. (Plan B)

---

## Execution Handoff

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batched checkpoints for review.
