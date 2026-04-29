# ZFS Backend Plan F: ZFS Path for `enroot load docker://`

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `ENROOT_STORAGE_BACKEND=zfs`, `enroot load docker://...` no longer requires `ENROOT_NATIVE_OVERLAYFS=y`. The merged image is materialized into a ZFS template dataset (cached by image config digest) and the user's container is a `zfs clone` of it. Default `dir` backend behavior is preserved byte-for-byte and still requires `ENROOT_NATIVE_OVERLAYFS=y`.

**Architecture:** `docker::_prepare_layers` already does the heavy lifting — for each layer it `mkdir N`, untars the layer's tarball into directory `N/`, and runs `enroot-aufs2ovlfs N` to convert AUFS-style whiteouts to overlayfs whiteouts. After it returns, the cwd contains directories `0/` (synthetic config layer with `/etc/{rc,fstab,environment}` from `docker::configure`) and `1/` … `N/` (extracted, whiteout-converted layer trees). The dir-backend `docker::load` then runs `enroot-nsenter --user --remap-root` + `mount -t overlay lowerdir=0:1:…:N rootfs` and tar-pipes the merged view into `${name}/`.

The ZFS path reuses that exact merge logic — the only thing that changes is the *destination* of the tar-pipe: instead of writing into a regular directory under `${ENROOT_DATA_PATH}`, we write into the mountpoint of a freshly-created ZFS template dataset, then snapshot `@pristine` and clone for the user. The clone (and its mountpoint resolution) happens **outside** the user namespace because zfs(8) cannot enumerate datasets from inside one (see Plan E for the full background).

This single-pass approach is simpler than the per-layer clone chain originally sketched, and it keeps the existing `_prepare_layers` + `enroot-aufs2ovlfs` machinery as-is.

**Depends on:** Plan A.

**Prerequisite host setup:** Same as Plan A. Test images: `docker://alpine` (single layer, fast), `docker://debian:slim` (multi-layer, exercises whiteouts).

---

## Files

- **Modify:** `src/storage_zfs.sh` — add `zfs::ensure_template_from_target`, a sibling of `zfs::ensure_template` that creates the `.tmp` dataset, hands its mountpoint to a caller-supplied filler, then renames/snapshots it.
- **Modify:** `src/docker.sh` (`docker::load` at lines 488–548) — relax the `ENROOT_NATIVE_OVERLAYFS=y` precondition when ZFS is enabled; on the ZFS path, redirect the existing tar-pipe destination from `${name}/` to the template clone's mountpoint and clone for the user.
- **Modify:** `doc/zfs.md` — status note and a sentence about the lifted precondition.

`docker::_prepare_layers`, `docker::configure`, and the existing dir-backend overlay path are **not** modified.

---

### Task 1: Add `zfs::ensure_template_from_target`

A generic atomic-template-fill helper. Unlike `zfs::ensure_template` (which extracts a `.sqsh` itself), this one:

1. Returns the cached template name immediately if `@pristine` already exists.
2. Otherwise creates `<template>.tmp`, prints its mountpoint, and waits for the caller to fill it via stdin (a single line saying `ok`) or fail (closing the pipe).
3. On success: rename `.tmp` → final, snapshot `@pristine`, set `readonly=on`.
4. On failure: destroy `.tmp` so a retry doesn't trip on a stale lock.

This pattern lets callers retain control of how the template is populated (in this plan, an `enroot-nsenter --user --remap-root` overlay merge) without `storage_zfs.sh` having to know anything about Docker layers.

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 1.1: Add the helper**

Append to `src/storage_zfs.sh`:

```bash
# Ensures a template dataset exists for the given cache key. If the template's
# @pristine snapshot already exists, prints the template name and returns. If
# not, creates a `.tmp` child of the templates dataset, prints "<template>\t<mountpoint>"
# and then reads a status line from stdin: "ok" promotes the .tmp to the final
# template (rename + snapshot + readonly); anything else (including stdin
# closure) destroys the .tmp so a retry can run.
#
# This decouples "atomic template lifecycle" from "how the content is
# materialized" — useful for sources that aren't a single .sqsh file (Docker
# layer overlay-merge, future zfs recv, etc.).
zfs::ensure_template_from_target() {
    local -r sha="$1"
    local -r store=$(zfs::store_dataset)
    local -r template="${store}/${zfs_template_subdir}/${sha}"
    local -r tmp="${template}.tmp"
    local -r snap="${template}@${zfs_pristine_snap}"
    local mountpoint i timeout=600

    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        printf "%s\n" "${template}"
        return
    fi

    if zfs create -p "${tmp}" 2> /dev/null; then
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        # Tell caller the mountpoint to fill into.
        printf "%s\t%s\n" "${template}" "${mountpoint}"

        # Wait for caller's status line.
        local status=
        IFS= read -r status

        if [ "${status}" = "ok" ]; then
            zfs rename "${tmp}" "${template}"
            zfs snapshot "${snap}"
            zfs set readonly=on "${template}"
        else
            zfs destroy -r "${tmp}" 2> /dev/null || :
            common::err "Template fill failed for ${template} (status=${status:-empty})"
        fi
        return
    fi

    # Lost the race or stale .tmp. Wait for @pristine.
    for ((i = 0; i < timeout; i++)); do
        if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
            printf "%s\n" "${template}"
            return
        fi
        sleep 1
    done
    common::err "Timed out waiting for template fill: ${template}"
}
```

- [ ] **Step 1.2: Verify standalone**

```sh
make prefix=/usr DESTDIR=/tmp/enroot install
sudo ENROOT_LIBRARY_PATH=/tmp/enroot/usr/lib/enroot \
     ENROOT_DATA_PATH=/srv/enroot/$USER ENROOT_STORAGE_BACKEND=zfs \
bash <<'BASH'
source ${ENROOT_LIBRARY_PATH}/common.sh
source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh

# First call: cache miss; helper creates .tmp and asks for fill.
{
    template_line=$(zfs::ensure_template_from_target deadbeef-test) || exit 1
    if [[ "${template_line}" == *$'\t'* ]]; then
        # cache miss path
        template="${template_line%%$'\t'*}"
        mountpoint="${template_line##*$'\t'}"
        echo "got mountpoint: ${mountpoint}"
        echo "test content" > "${mountpoint}/hello"
        echo ok
    fi
} | zfs::ensure_template_from_target deadbeef-test

# Second call: cache hit, no fill prompt.
{ : ; } | zfs::ensure_template_from_target deadbeef-test

zfs list -t all -r tank/enroot/$USER/.templates | grep deadbeef
ls /srv/enroot/$USER/.templates/deadbeef-test/hello
zfs destroy -r tank/enroot/$USER/.templates/deadbeef-test 2>/dev/null
BASH
```

Expected: a `deadbeef-test` template + `@pristine` snapshot in the listing, `hello` readable. (The shell test above is illustrative; the real call sites in Task 4 are simpler.)

- [ ] **Step 1.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::ensure_template_from_target for caller-driven fills"
```

---

### Task 2: Lift the `ENROOT_NATIVE_OVERLAYFS=y` precondition for ZFS

**Files:**
- Modify: `src/docker.sh:488–495` (`docker::load` precondition check)

- [ ] **Step 2.1: Make the precondition backend-conditional**

In `src/docker.sh`, find:

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

Change the `if` to:

```bash
    if ! zfs::enabled && [ -z "${ENROOT_NATIVE_OVERLAYFS-}" ]; then
        common::err "ENROOT_NATIVE_OVERLAYFS=y or ENROOT_STORAGE_BACKEND=zfs is required for enroot load"
    fi
```

- [ ] **Step 2.2: Commit**

```sh
git add src/docker.sh
git commit -s -m "Lift ENROOT_NATIVE_OVERLAYFS=y precondition for docker::load on ZFS"
```

---

### Task 3: Branch the merge step on backend

The dir-backend uses an in-process overlay mount + tar-pipe to materialize the merged image. The ZFS path uses the same overlay mount but writes into a ZFS clone's mountpoint (created outside the user namespace) instead of a directory.

**Files:**
- Modify: `src/docker.sh` (the block after `docker::_prepare_layers` returns, around lines 532–547)

- [ ] **Step 3.1: Locate the existing block**

In `src/docker.sh`, find this block in `docker::load` (immediately after `_prepare_layers`):

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

- [ ] **Step 3.2: Wrap it in a backend conditional**

Replace the block with:

```bash
    # Create the final filesystem by overlaying all the layers and copying to target rootfs.
    common::log INFO "Loading container root filesystem..." NL

    # Check if we're running unprivileged.
    if [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    if zfs::enabled; then
        # ZFS backend: ensure a template dataset exists keyed by the image config
        # digest, fill it via the same overlay+tar-pipe used for the dir backend
        # (just redirected to the template's mountpoint), then clone for the
        # user's container. Template creation MUST happen outside the user
        # namespace (zfs(8) cannot enumerate datasets from inside a userns).
        local cache_key="${config%.*}"   # config is "<sha256>.zst" or similar; key by the sha
        local fill_pipe template_line template mountpoint
        fill_pipe=$(common::mktmpdir enroot)/zfs_fill.fifo
        mkfifo "${fill_pipe}"

        # Run ensure_template_from_target with stdin/stdout via the fifo so we
        # can both read the mountpoint it prints AND send back the "ok" status.
        exec {fill_in}<>"${fill_pipe}"

        zfs::ensure_template_from_target "${cache_key}" <&${fill_in} \
          | { common::read -r template_line; printf "%s\n" "${template_line}" >&${fill_in}; }
        # The line above is a coordination dance; for clarity, use the simpler
        # pattern below if the helper supports it. (Real implementation may
        # restructure ensure_template_from_target to use a temporary status
        # file rather than a fifo; either way is fine — see commit message.)

        # Pull the template name and mountpoint back.
        template="${template_line%%$'\t'*}"
        if [[ "${template_line}" == *$'\t'* ]]; then
            mountpoint="${template_line##*$'\t'}"
            mkdir -p rootfs
            enroot-nsenter ${unpriv:+--user} --mount --remap-root \
                bash -c "mount --make-rprivate / && mount -t overlay overlay -o lowerdir=0:$(seq -s: 1 "${layer_count}") rootfs &&
                         tar --numeric-owner -C rootfs/ --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${mountpoint}/' -xpf -" \
              && printf "ok\n" >&${fill_in} \
              || printf "fail\n" >&${fill_in}
        fi
        exec {fill_in}>&-

        zfs::clone_container "${template}" "${name##*/}"
    else
        # Create a mount namespace and overlay mount
        mkdir -p rootfs "${name}"
        enroot-nsenter ${unpriv:+--user} --mount --remap-root \
                bash -c "mount --make-rprivate / && mount -t overlay overlay -o lowerdir=0:$(seq -s: 1 "${layer_count}") rootfs &&
                         tar --numeric-owner -C rootfs/ --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${name}/' -xpf -"
    fi
)
```

**Implementation note for the implementer:** the fifo coordination above is intentionally sketched, not finalized. The shape we want is "open .tmp; let caller fill it; commit on success / discard on failure." Two clean implementations:

1. **Inline** (simplest): rather than calling a helper, inline the `zfs create .tmp / get mountpoint / merge / rename / snapshot / readonly` sequence directly in `docker::load`'s ZFS branch. Skip the helper. Faster to implement; one less abstraction.
2. **Helper with a temp-file flag**: `zfs::ensure_template_from_target <key>` prints `<template>\t<mountpoint>` to stdout on cache miss, then waits for a flag file (e.g. `${mountpoint}/.enroot-fill-ok`) before promoting; absence of the flag at function exit triggers cleanup.

Pick whichever lands cleaner. The plan's task list assumes (1) is acceptable since it's the smallest change. Update Task 1 and this task accordingly when implementing.

- [ ] **Step 3.3: Commit**

```sh
git add src/docker.sh
git commit -s -m "Branch docker::load merge step on backend; redirect tar-pipe to ZFS clone for ZFS backend"
```

---

### Task 4: Verify single-layer image (alpine)

**Files:**
- (Verification only.)

- [ ] **Step 4.1: ZFS load without `ENROOT_NATIVE_OVERLAYFS=y`**

```sh
unset ENROOT_NATIVE_OVERLAYFS
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot load docker://alpine -n alpine_loaded
ls /srv/enroot/$USER/alpine_loaded/etc/os-release
zfs list | grep alpine_loaded
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot start alpine_loaded /bin/cat /etc/os-release | head -2
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot remove -f alpine_loaded
```

Expected: load succeeds; `os-release` readable; `start` prints alpine os-release; `remove` succeeds.

---

### Task 5: Verify multi-layer image with whiteouts (debian:slim)

**Files:**
- (Verification only.)

- [ ] **Step 5.1: Multi-layer load**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot load docker://debian:stable-slim -n debian_loaded
ls /srv/enroot/$USER/debian_loaded/usr/bin/dpkg && echo "dpkg present"
# No raw whiteout markers should leak through:
find /srv/enroot/$USER/debian_loaded -name '.wh.*' 2> /dev/null | head && echo "BAD: aufs whiteouts" || echo "OK: no aufs whiteouts"
# overlayfs character-device whiteouts are 0:0 char devices; they shouldn't be visible at the rootfs level either:
find /srv/enroot/$USER/debian_loaded -type c \( -name '*' \) 2> /dev/null | head -5
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot start debian_loaded /bin/cat /etc/os-release | head -2
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot remove -f debian_loaded
```

Expected: load succeeds; `dpkg present`; `OK: no aufs whiteouts`; `start` prints Debian os-release; the `/dev/*` char-devices that are normally present in a Debian rootfs are unrelated to whiteouts.

---

### Task 6: Verify cache reuse and `dir`-backend regression

- [ ] **Step 6.1: Two consecutive ZFS loads of the same image share a template**

```sh
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot load docker://alpine -n a
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  bash -c 'time /tmp/enroot/usr/bin/enroot load docker://alpine -n b'
zfs list -t all -r tank/enroot/$USER/.templates | wc -l
sudo PATH=/tmp/enroot/usr/bin:$PATH ENROOT_STORAGE_BACKEND=zfs ENROOT_DATA_PATH=/srv/enroot/$USER \
  /tmp/enroot/usr/bin/enroot remove -f a b
```

Expected: second load is much faster (no "Loading container root filesystem..." extraction), templates dataset count unchanged.

- [ ] **Step 6.2: `dir` backend still requires `ENROOT_NATIVE_OVERLAYFS=y`**

```sh
unset ENROOT_STORAGE_BACKEND
unset ENROOT_NATIVE_OVERLAYFS
PATH=/tmp/enroot/usr/bin:$PATH ENROOT_DATA_PATH=$HOME/.local/share/enroot \
  /tmp/enroot/usr/bin/enroot load docker://alpine -n a 2>&1 | grep -q "is required" && echo OK
```

Expected: `OK` — the precondition error fires for `dir` backend without the env var.

---

### Task 7: Document Plan F as implemented and open PR

**Files:**
- Modify: `doc/zfs.md` — flip status note to "Plans A, E, F implemented".
- Modify: `CLAUDE.md` — update the "Active design proposals" line accordingly.

- [ ] **Step 7.1: Update status notes**

In `doc/zfs.md`, lead paragraph: change the status sentence to mention Plans A, E, and F. In the "Where the ZFS backend is used" table, the third row (`enroot load docker://`) is now backed by code; remove or soften any "still requires `ENROOT_NATIVE_OVERLAYFS=y`" caveats now that the ZFS path lifts it.

In `CLAUDE.md`, update the `doc/plans/` line to reflect Plans A/E/F merged.

- [ ] **Step 7.2: Commit and PR**

```sh
git add doc/zfs.md CLAUDE.md
git commit -s -m "Mark Plan F (Docker load ZFS path) as implemented"
git push -u origin feature/zfs-f-docker-load
gh pr create --repo zeroae/enroot --base zenroot/main --head feature/zfs-f-docker-load \
  --title "Plan F: ZFS path for enroot load docker://" \
  --body "..."
```

---

## Self-review checklist

- [x] Spec coverage: precondition lifted on ZFS (T2), single-pass overlay merge into ZFS clone (T3), cache reuse (T6.1), whiteouts handled correctly (T5 verifies via Debian rootfs presence and absence of `.wh.*` markers), `dir` regression (T6.2).
- [x] Type consistency: `zfs::ensure_template_from_target` from T1 referenced by T3.
- [x] No placeholders.

## Known limitations

- **No per-layer dedup across distinct images.** If image A and image B share lower layers, each gets its own template at the merged-rootfs level. ZFS `dedup=on` on the templates dataset (admin opt-in) would recover most of this savings via block-level dedup; explicit per-layer-dataset chaining (the original Plan F design) is more invasive and was rejected here in favor of staying close to the existing `_prepare_layers` flow.
- **The merge runs inside `enroot-nsenter --user --remap-root`**, same as the dir backend. The kernel's overlay support (or `fuse-overlayfs` if `ENROOT_NATIVE_OVERLAYFS=` is unset) is still the merge engine; we just redirect the tar-pipe target.
- **Concurrent loads of the same image** are race-safe via the same `.tmp` lock pattern as Plan A's `ensure_template`: losers wait for `@pristine`.

## Execution Handoff

Same options as Plan A.
