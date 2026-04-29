# ZFS Backend Plan E: ZFS Path for Ephemeral `start <image>`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user runs `enroot start foo.sqsh` (no prior `create` — the image path is given directly), and `ENROOT_STORAGE_BACKEND=zfs`, substitute the existing `squashfuse + overlayfs` ephemeral mount with `ensure_template + zfs clone` to a unique throwaway dataset that is destroyed when the container exits. Existing behavior on the `dir` backend, and on non-ZFS hosts, is unchanged.

**Architecture:** Branch in `runtime::_mount_rootfs` (`src/runtime.sh:174-211`). On the ZFS path, the function instead arranges for an ephemeral clone, returns its mountpoint as the new `_rootfs`, and registers a cleanup hook so the clone is destroyed even if the parent process is killed. The fuse-shim machinery is bypassed entirely on this path.

**Depends on:** Plan A.

**Prerequisite host setup:** Same as Plan A.

---

## Files

- **Modify:** `src/runtime.sh:174-211` (`runtime::_mount_rootfs`).
- **Modify:** `src/runtime.sh:213-282` (`runtime::_start`) — register cleanup.
- **Modify:** `src/storage_zfs.sh` — add `zfs::ephemeral_clone`, `zfs::ephemeral_destroy`.

---

### Task 1: Add `zfs::ephemeral_clone` and `zfs::ephemeral_destroy`

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 1.1: Add the helpers**

Append to `src/storage_zfs.sh`:

```bash
readonly zfs_ephemeral_subdir=".ephemeral"

# Creates an ephemeral clone of the template for the given image and prints its
# mountpoint. The clone name embeds the host PID for uniqueness and so the
# cleanup hook can find it. The container is intended to be torn down when the
# enroot process exits.
zfs::ephemeral_clone() {
    local -r image="$1"
    local -r store=$(zfs::store_dataset)
    local sha template clone mountpoint

    sha=$(zfs::image_sha256 "${image}")
    template=$(zfs::ensure_template "${image}" "${sha}")

    clone="${store}/${zfs_ephemeral_subdir}/${$}-${sha:0:12}"
    zfs create -p "${store}/${zfs_ephemeral_subdir}" 2> /dev/null || :
    zfs clone "${template}@${zfs_pristine_snap}" "${clone}"
    zfs set readonly=off "${clone}"

    mountpoint=$(zfs get -H -o value mountpoint "${clone}")
    printf "%s\t%s" "${clone}" "${mountpoint}"
}

# Destroys an ephemeral clone. Best-effort; intended for cleanup hooks.
zfs::ephemeral_destroy() {
    local -r clone="$1"
    [ -z "${clone}" ] && return
    zfs destroy "${clone}" 2> /dev/null || :
}
```

- [ ] **Step 1.2: Verify standalone**

```sh
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         out=$(zfs::ephemeral_clone alpine.sqsh)
         echo "got: ${out}"
         clone="${out%%	*}"
         mp="${out##*	}"
         ls "${mp}/etc/os-release" && echo OK
         zfs::ephemeral_destroy "${clone}"
         zfs list | grep -q ephemeral || echo "cleaned"'
```

Expected: `OK` and `cleaned`.

- [ ] **Step 1.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::ephemeral_clone and zfs::ephemeral_destroy"
```

---

### Task 2: Branch `runtime::_mount_rootfs` on backend

**Files:**
- Modify: `src/runtime.sh:174-211` (`runtime::_mount_rootfs`)

- [ ] **Step 2.1: Add a ZFS branch at the top of the function**

In `src/runtime.sh:174`, change:

```bash
runtime::_mount_rootfs() {
    local -r image="$1" rootfs="$2"
    local pid=0 rv=0

    common::checkcmd squashfuse mountpoint
    if [ -z "${ENROOT_NATIVE_OVERLAYFS-}" ]; then
        common::checkcmd fuse-overlayfs
    fi
    ...
```

to:

```bash
runtime::_mount_rootfs() {
    local -r image="$1" rootfs="$2"
    local pid=0 rv=0

    if zfs::enabled; then
        runtime::_mount_rootfs_zfs "${image}" "${rootfs}"
        return
    fi

    common::checkcmd squashfuse mountpoint
    if [ -z "${ENROOT_NATIVE_OVERLAYFS-}" ]; then
        common::checkcmd fuse-overlayfs
    fi
    ...
```

(Leave the existing body intact below the new branch — that path is still used on non-ZFS hosts and on the `dir` backend.)

- [ ] **Step 2.2: Add `runtime::_mount_rootfs_zfs`**

Append a new function to `src/runtime.sh` (after `runtime::_mount_rootfs`):

```bash
runtime::_mount_rootfs_zfs() {
    local -r image="$1" rootfs="$2"
    local out clone mountpoint

    zfs::checkenv

    out=$(zfs::ephemeral_clone "${image}")
    clone="${out%%$'\t'*}"
    mountpoint="${out##*$'\t'}"

    # Make the ephemeral clone visible at the canonical rootfs path the caller expects.
    # The caller will bind-mount and pivot from this path; we redirect by bind-mounting
    # the clone's mountpoint onto the placeholder rootfs.
    cat <<- EOF | enroot-mount -
	${mountpoint} ${rootfs} none rbind
	EOF

    # Register cleanup. Stash the clone name in a runtime file so the parent shell
    # can destroy it after the container exits (see runtime::_start).
    printf "%s\n" "${clone}" > "${ENROOT_RUNTIME_PATH}/zfs_ephemeral"
}
```

- [ ] **Step 2.3: Commit**

```sh
git add src/runtime.sh
git commit -s -m "Branch runtime::_mount_rootfs on ZFS backend for ephemeral starts"
```

---

### Task 3: Wire ephemeral cleanup in `runtime::_start`

**Files:**
- Modify: `src/runtime.sh:213-282` (`runtime::_start`)

- [ ] **Step 3.1: Add a trap that destroys the ephemeral clone**

In `runtime::_start`, locate the existing `trap` setup or the area near the top of the function. Add:

```bash
    # If we created an ephemeral ZFS clone in _mount_rootfs, destroy it on exit.
    if [ -f "${ENROOT_RUNTIME_PATH}/zfs_ephemeral" ]; then
        local zfs_ephemeral_clone
        zfs_ephemeral_clone=$(< "${ENROOT_RUNTIME_PATH}/zfs_ephemeral")
        trap 'zfs::ephemeral_destroy "${zfs_ephemeral_clone}"' EXIT
    fi
```

Place this after the existing tmpfs setup (around line 226), but before the rootfs mount block at line 232.

- [ ] **Step 3.2: Verify ephemeral lifecycle end-to-end**

```sh
export ENROOT_STORAGE_BACKEND=zfs
export ENROOT_DATA_PATH=/srv/enroot/$USER
zfs list -t all | grep ephemeral || echo "none yet"
/tmp/enroot/usr/bin/enroot start alpine.sqsh /bin/echo hello
zfs list -t all | grep ephemeral || echo "cleaned"
```

Expected: first check prints `none yet`; the start prints `hello`; final check prints `cleaned`.

- [ ] **Step 3.3: Verify the template stays warm across ephemeral starts**

```sh
# First start: extract.
time /tmp/enroot/usr/bin/enroot start alpine.sqsh /bin/true
# Second start: should be fast (template already cached).
time /tmp/enroot/usr/bin/enroot start alpine.sqsh /bin/true
zfs list -t all -r tank/enroot/$USER/.templates | head
```

Expected: second invocation noticeably faster; template persists.

- [ ] **Step 3.4: Verify `dir` backend ephemeral start still uses overlayfs**

```sh
unset ENROOT_STORAGE_BACKEND
export ENROOT_DATA_PATH=$HOME/.local/share/enroot
/tmp/enroot/usr/bin/enroot start alpine.sqsh /bin/echo hello
```

Expected: prints `hello`. Squashfuse + overlayfs path was used (no ZFS calls).

- [ ] **Step 3.5: Commit**

```sh
git add src/runtime.sh
git commit -s -m "Add ephemeral ZFS clone cleanup on container exit"
```

---

### Task 4: Document Plan E as implemented

**Files:**
- Modify: `doc/zfs.md`

- [ ] **Step 4.1: Update status note**

Update `doc/zfs.md` to mark Plan E (ephemeral start ZFS path) as landed.

- [ ] **Step 4.2: End-to-end smoke**

```sh
export ENROOT_STORAGE_BACKEND=zfs
zfs list -t all -r tank/enroot/$USER | wc -l
for i in 1 2 3 4 5; do
    /tmp/enroot/usr/bin/enroot start alpine.sqsh /bin/true
done
zfs list -t all -r tank/enroot/$USER | wc -l   # should be the same as before — only the warm template, no ephemeral leftovers
zfs list -t all -r tank/enroot/$USER | grep ephemeral && echo BAD || echo OK
```

Expected: `OK`.

- [ ] **Step 4.3: Commit**

```sh
git add doc/zfs.md
git commit -s -m "Mark Plan E (ephemeral start ZFS path) as implemented"
```

---

## Self-review checklist

- [x] Spec coverage: ZFS path for ephemeral `start <image>` (T2, T3); cleanup on exit (T3.1); template-cache reuse across ephemeral starts (T3.3); non-ZFS path untouched (T2.1 leaves the original block intact below the branch; T3.4 verifies).
- [x] Type consistency: `zfs::ephemeral_clone`, `zfs::ephemeral_destroy` from T1 are referenced in T2, T3.
- [x] No placeholders.

## Known limitations

- The ephemeral clone goes to a `.ephemeral/` subdataset rather than tmpfs; if the container writes huge amounts of throwaway data, it counts against the pool's quota until destroy. A future plan could bound this with a per-clone quota.
- Cleanup is best-effort via shell trap. If `enroot` is hard-killed (`kill -9`), the ephemeral clone leaks until the next manual cleanup or process restart. A safety net (sweep `.ephemeral/` for clones whose PID is dead) could be added to `zfs::sweep_templates` if leaks become a problem in practice.

## Execution Handoff

Same options as Plan A.
