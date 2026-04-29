# ZFS Backend Plan E: ZFS Path for Ephemeral `start <image>`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the user runs `enroot start foo.sqsh` (no prior `create` — the image path is given directly), and `ENROOT_STORAGE_BACKEND=zfs`, substitute the existing `squashfuse + overlayfs` ephemeral mount with `ensure_template + zfs clone` to a unique throwaway dataset that is destroyed when the container exits. Existing behavior on the `dir` backend, and on non-ZFS hosts, is unchanged. The original `exec enroot-nsenter ...` chain is preserved end-to-end, so PID semantics, signal forwarding, and `enroot exec PID` are unaffected.

**Architecture:** The clone is created in `runtime::start` *before* the user-namespace transition, because `zfs list` cannot enumerate datasets from inside a Linux user namespace (zfs-2.4.x's ioctl handlers gate dataset visibility on `current_user_ns() == &init_user_ns`; no module parameter or capability changes this on current OpenZFS). Cleanup is handled by a small subshell ("zfs-eph-shim") modeled on the existing `runtime::_mount_rootfs_shim` pattern: forked into its own process group via `set -m`, parked with `SIGSTOP`, and triggered to run `zfs::ephemeral_destroy` via the kernel's orphaned-process-group `SIGHUP` rule when the parent's exec chain (`enroot-nsenter` → bash → `enroot-switchroot` → container) exits. The original `exec enroot-nsenter ...` line is unchanged. The container then sees the clone's mountpoint as a directory rootfs and the existing directory-rootfs path in `runtime::_start` operates on it identically to a `dir`-backend named container.

**Depends on:** Plan A.

**Prerequisite host setup:** Same as Plan A.

---

## Files

- **Modify:** `src/runtime.sh` — `source storage_zfs.sh` near the top (so `zfs::*` is available in the `BASH_ENV`-loaded subshell after nsenter); add a ZFS branch with the cleanup shim near the end of `runtime::start`.
- **Modify:** `src/storage_zfs.sh` — add `zfs::ephemeral_clone` and `zfs::ephemeral_destroy`.
- **Modify:** `doc/zfs.md` — status note + Linux user-namespace caveat.

`runtime::_mount_rootfs` (squashfuse + overlay path) is **not** modified — that path continues to serve non-ZFS hosts and the `dir` backend.

---

### Task 1: Add `zfs::ephemeral_clone` and `zfs::ephemeral_destroy`

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 1.1: Add the helpers**

Append to `src/storage_zfs.sh`:

```bash
readonly zfs_ephemeral_subdir=".ephemeral"

# Creates an ephemeral clone of the template for the given image and prints its
# clone dataset name and mountpoint (tab-separated). The clone name embeds the
# host PID for uniqueness so concurrent enroot processes don't collide and so
# the cleanup hook can find the right clone. Intended to be torn down via
# zfs::ephemeral_destroy when the enroot process exits.
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

Also add the new subdir constant alongside the existing template constants near the top of the file:

```bash
readonly zfs_ephemeral_subdir=".ephemeral"
```

- [ ] **Step 1.2: Verify standalone**

```sh
make prefix=/usr DESTDIR=/tmp/enroot install
sudo ENROOT_LIBRARY_PATH=/tmp/enroot/usr/lib/enroot \
     ENROOT_DATA_PATH=/srv/enroot/$USER \
     ENROOT_STORAGE_BACKEND=zfs ENROOT_MAX_PROCESSORS=2 \
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         out=$(zfs::ephemeral_clone /tmp/alpine.sqsh)
         clone="${out%%	*}"
         mp="${out##*	}"
         ls "${mp}/etc/os-release" && echo "rootfs OK"
         zfs::ephemeral_destroy "${clone}"'
zfs list -t all | grep '\.ephemeral/[0-9]' && echo "BAD: clone leaked" || echo "OK: cleaned"
```

Expected: `rootfs OK` and `OK: cleaned`.

- [ ] **Step 1.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::ephemeral_clone and zfs::ephemeral_destroy"
```

---

### Task 2: Wire ephemeral lifecycle into `runtime::start`

**Files:**
- Modify: `src/runtime.sh` — add `source storage_zfs.sh` near the top; add ZFS branch with cleanup shim before the existing `exec enroot-nsenter ...` line in `runtime::start`.

The clone must be created before `enroot-nsenter --user`. The cleanup must survive the `exec` chain. We solve both with a small subshell forked into its own process group, parked with `SIGSTOP`, that the kernel will deliver `SIGHUP+SIGCONT` to once its process group is orphaned (i.e. the moment the parent's container chain exits, including under `kill -9`). This mirrors `runtime::_mount_rootfs_shim` (`src/runtime.sh:141-172`).

- [ ] **Step 2.1: Source `storage_zfs.sh` from `runtime.sh`**

After Plan A, `runtime.sh` sources only `common.sh` at the top. Inside `runtime::start`, the script `exec`s a fresh bash via `enroot-nsenter` that loads `runtime.sh` via `BASH_ENV`. That fresh bash needs `zfs::*` symbols available even though it never runs through `enroot.in`'s top-level source chain.

In `src/runtime.sh`, find:

```bash
source "${ENROOT_LIBRARY_PATH}/common.sh"

readonly hook_dirs=(...)
```

and change it to:

```bash
source "${ENROOT_LIBRARY_PATH}/common.sh"
source "${ENROOT_LIBRARY_PATH}/storage_zfs.sh"

readonly hook_dirs=(...)
```

- [ ] **Step 2.2: Add the ZFS branch with shim to `runtime::start`**

In `src/runtime.sh`, locate `runtime::start`. Find the block:

```bash
    # Check if we're running unprivileged.
    if [ -z "${ENROOT_ALLOW_SUPERUSER-}" ] || [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    # Create new namespaces and start the container.
    export BASH_ENV="${BASH_SOURCE[0]}"
    exec enroot-nsenter ${unpriv:+--user} --mount ${ENROOT_REMAP_ROOT:+--remap-root} \
      "${BASH}" --norc -o ${SHELLOPTS//:/ -o } -O ${BASHOPTS//:/ -O } -c \
      'runtime::_start "$@"' "${config}" "${rootfs}" "${rc}" "${config}" "${mounts}" "${environ}" "$@"
}
```

Insert the ZFS branch *between* the `unpriv=y` block and the `exec` line:

```bash
    # Check if we're running unprivileged.
    if [ -z "${ENROOT_ALLOW_SUPERUSER-}" ] || [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    # ZFS backend: when starting from an image file, clone the template into an
    # ephemeral dataset BEFORE entering the user namespace (zfs(8) cannot
    # enumerate datasets from inside a userns) and fork a shim into its own
    # process group to destroy the clone when the container exits. The shim
    # mirrors runtime::_mount_rootfs_shim's orphaned-process-group cleanup
    # pattern: it parks itself with SIGSTOP, gets SIGHUP'd by the kernel once
    # this shell's exec'd container chain exits, and then runs zfs destroy.
    if zfs::enabled && [ -f "${rootfs}" ]; then
        local _zfs_eph_out _zfs_eph_clone _zfs_eph_mountpoint _zfs_eph_pid _zfs_eph_rv=0
        _zfs_eph_out=$(zfs::ephemeral_clone "${rootfs}")
        _zfs_eph_clone="${_zfs_eph_out%%$'\t'*}"
        _zfs_eph_mountpoint="${_zfs_eph_out##*$'\t'}"

        set -m
        (
            exec -a zfs-eph-shim "${BASH}" <<- EOF
		$(declare -f zfs::ephemeral_destroy common::log common::fmt)
		runtime::_zfs_ephemeral_shim() {
		    trap "zfs::ephemeral_destroy '${_zfs_eph_clone}'; exit 0" SIGHUP
		    kill -STOP \$\$
		}
		runtime::_zfs_ephemeral_shim
		EOF
        ) > /dev/null 2>&1 & _zfs_eph_pid=$!

        # Wait for the shim to park itself (exit code 128+SIGSTOP=147).
        wait "${_zfs_eph_pid}" 2> /dev/null || _zfs_eph_rv=$?
        set +m
        if ((_zfs_eph_rv != 128 + 19)); then
            zfs::ephemeral_destroy "${_zfs_eph_clone}"
            common::err "ZFS ephemeral cleanup shim failed to start (rv=${_zfs_eph_rv})"
        fi
        disown "${_zfs_eph_pid}" > /dev/null 2>&1

        rootfs="${_zfs_eph_mountpoint}"
    fi

    # Create new namespaces and start the container.
    export BASH_ENV="${BASH_SOURCE[0]}"
    exec enroot-nsenter ${unpriv:+--user} --mount ${ENROOT_REMAP_ROOT:+--remap-root} \
      "${BASH}" --norc -o ${SHELLOPTS//:/ -o } -O ${BASHOPTS//:/ -O } -c \
      'runtime::_start "$@"' "${config}" "${rootfs}" "${rc}" "${config}" "${mounts}" "${environ}" "$@"
}
```

The `exec enroot-nsenter ...` line is unchanged — the shim runs alongside, not instead of, the original chain.

- [ ] **Step 2.3: Verify ephemeral lifecycle end-to-end**

```sh
make prefix=/usr DESTDIR=/tmp/enroot install
zfs list -t all -r tank/enroot/$USER/.ephemeral 2>&1 | grep '/[0-9]' || echo "none yet"
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot start /tmp/alpine.sqsh /bin/echo hello
zfs list -t all -r tank/enroot/$USER/.ephemeral 2>&1 | grep '/[0-9]' && echo "BAD: leaked" || echo "OK: cleaned"
```

Expected: first probe `none yet`; start prints `hello`; final probe `OK: cleaned`.

- [ ] **Step 2.4: Verify the template stays warm across ephemeral starts**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  bash -c 'time /tmp/enroot/usr/bin/enroot start /tmp/alpine.sqsh /bin/true'
```

Expected: completes in well under a second; no "Extracting squashfs filesystem" log line on the second invocation.

- [ ] **Step 2.5: Verify `dir` backend ephemeral start still uses overlayfs**

```sh
unset ENROOT_STORAGE_BACKEND
PATH=/tmp/enroot/usr/bin:$PATH ENROOT_DATA_PATH=$HOME/.local/share/enroot ENROOT_NATIVE_OVERLAYFS=y \
  /tmp/enroot/usr/bin/enroot start /tmp/alpine.sqsh /bin/echo dir-backend-ok
```

Expected: prints `dir-backend-ok`. Squashfuse + overlay path was used; no ZFS calls.

- [ ] **Step 2.6: Verify `enroot exec PID` against an ephemeral container**

This is the headline reason for the shim approach over a no-exec parent.

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot start /tmp/alpine.sqsh /bin/sleep 30 &
SP=$!; sleep 2
ENROOT_PID=$(pgrep -P $(pgrep -f '^sudo.*enroot start /tmp/alpine'))
ps -p ${ENROOT_PID} -o pid,comm
sudo PATH=/tmp/enroot/usr/bin:$PATH /tmp/enroot/usr/bin/enroot exec ${ENROOT_PID} /bin/echo "exec-into-PID-works"
sudo kill -9 ${ENROOT_PID}; wait $SP 2>/dev/null
```

Expected: `ps` shows `sleep` (the container's leaf process), `enroot exec` prints `exec-into-PID-works`, no ephemeral leftovers afterwards.

- [ ] **Step 2.7: Verify `kill -9` of the container does not leak**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot start /tmp/alpine.sqsh /bin/sleep 60 &
SP=$!; sleep 2
CONTAINER_PID=$(pgrep -f '^/bin/sleep 60$' | head -1)
sudo kill -9 "${CONTAINER_PID}"
wait $SP 2>/dev/null; sleep 2
zfs list -t all -r tank/enroot/$USER/.ephemeral | grep '/[0-9]' && echo "leaked" || echo "OK: cleaned"
```

Expected: `OK: cleaned` — the orphan-SIGHUP rule fires the shim's cleanup even on hard kill.

- [ ] **Step 2.8: Commit**

```sh
git add src/runtime.sh
git commit -s -m "Wire ephemeral ZFS clone setup and cleanup shim into runtime::start"
```

---

### Task 3: Document Plan E as implemented

**Files:**
- Modify: `doc/zfs.md`

- [ ] **Step 3.1: Update status note**

In `doc/zfs.md`, update the lead paragraph to mark Plans A and E as implemented.

- [ ] **Step 3.2: Document the user-namespace caveat**

Add a paragraph near the existing Linux mount(2) caveat in the admin setup section describing why ZFS work happens before `enroot-nsenter --user` and how the shim handles cleanup. Suggested wording:

> **Linux user-namespace caveat:** `zfs list` cannot enumerate datasets from inside a Linux user namespace — even when their mount entries are visible — so any ZFS work must happen *before* `enroot-nsenter --user`. For ephemeral `enroot start <image>`, the ephemeral clone is created in `runtime::start` outside the namespace; cleanup is handled by a small `zfs-eph-shim` subshell that mirrors the existing `runtime::_mount_rootfs_shim` pattern — forked into its own process group, parked with `SIGSTOP`, and triggered to `zfs destroy` via the kernel's orphaned-process-group `SIGHUP` rule when the container's exec chain exits. The original `exec enroot-nsenter ...` chain is preserved, so PID semantics, signal forwarding, and `enroot exec PID` all work identically to the `dir` backend.

- [ ] **Step 3.3: End-to-end smoke (5x ephemeral loop)**

```sh
before=$(zfs list -H -t all -r tank/enroot/$USER/.ephemeral 2>/dev/null | wc -l)
for i in 1 2 3 4 5; do
    sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
      /tmp/enroot/usr/bin/enroot start /tmp/alpine.sqsh /bin/true
done
after=$(zfs list -H -t all -r tank/enroot/$USER/.ephemeral 2>/dev/null | wc -l)
echo "before: ${before}, after: ${after}"
zfs list -t all -r tank/enroot/$USER/.ephemeral | grep '/[0-9]' && echo "BAD" || echo "OK"
```

Expected: `OK` — `before == after` (or +1 for the cache parent appearing on first run); no ephemeral subdataset leftovers.

- [ ] **Step 3.4: Commit**

```sh
git add doc/zfs.md
git commit -s -m "Mark Plan E (ephemeral start ZFS path) as implemented"
```

---

## Self-review checklist

- [x] Spec coverage: ZFS path for ephemeral `start <image>` (T2.2), cleanup on container exit (T2.2 shim), template-cache reuse across ephemeral starts (T2.4 verifies), non-ZFS path untouched (T2.5 verifies, no edits to `runtime::_mount_rootfs`), `enroot exec PID` semantics preserved (T2.6 verifies), `kill -9` cleanup via SIGHUP (T2.7 verifies).
- [x] Type consistency: `zfs::ephemeral_clone`, `zfs::ephemeral_destroy` defined in T1 are referenced from `runtime::start` and the inline `runtime::_zfs_ephemeral_shim` in T2.
- [x] No placeholders.

## Known limitations

- The ephemeral clone goes to a `.ephemeral/` subdataset rather than tmpfs; if the container writes huge amounts of throwaway data, it counts against the pool's quota until the shim destroys the clone.
- Cleanup relies on the kernel's POSIX orphaned-process-group `SIGHUP` rule. If the host crashes (full power loss, hard reboot), the shim never runs and ephemeral clones persist across boot. A boot-time sweep of `.ephemeral/*` (destroy children whose embedded PID is no longer live) could be added to the admin recipe in `doc/zfs.md`. Out of scope for this plan.
- The userns-vs-`zfs list` limitation is structural in OpenZFS as of zfs-2.4.x: dataset enumeration ioctls are not user-namespace-aware. No capability or module parameter (`zfs_admin_snapshot`, etc.) makes `zfs list` work inside the namespace on this version. If a future OpenZFS makes the iteration path userns-aware, the `runtime::start` placement of the clone could be reconsidered, but the cleanup shim would still be required because the `exec` chain (`enroot-nsenter` → bash → `enroot-switchroot` → container) leaves no surviving shell to fire an `EXIT` trap.

## Execution Handoff

Same options as Plan A.
