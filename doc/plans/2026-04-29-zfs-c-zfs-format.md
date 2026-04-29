# ZFS Backend Plan C: `.zfs` Image Format

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `.zfs` (zfs send stream) as a second image format alongside `.sqsh`. `enroot create foo.zfs` materializes the stream into the template cache via `zfs recv`, then clones to the user's container — semantically identical to `.sqsh` once the cache is populated, just with a different materialization step. `enroot export NAME --format=zfs` produces a `.zfs` file from a clone's `@pristine` snapshot. Hard error on a non-ZFS host. No magic-byte sniffing — extension is the contract.

**Architecture:** Dispatch on file extension at the entry point of `runtime::create` and `runtime::export`. Add a sibling to `zfs::ensure_template` that runs `zfs recv` instead of `unsquashfs`. Add a `zfs::send_stream` helper for export.

**Depends on:** Plan A.

**Prerequisite host setup:** Same as Plan A.

---

## Files

- **Modify:** `src/runtime.sh:391-...` (`runtime::create`) — extension-based dispatch.
- **Modify:** `src/runtime.sh:492-...` (`runtime::export`) — `--format=zfs` support.
- **Modify:** `src/storage_zfs.sh` — add `zfs::ensure_template_from_stream`, `zfs::send_stream`.
- **Modify:** `enroot.in:442-477` (`enroot::export`) — add `--format` flag.
- **Modify:** `enroot.in:127-137` (export usage string) — document `--format`.

---

### Task 1: Add `zfs::ensure_template_from_stream`

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 1.1: Add the function**

Append to `src/storage_zfs.sh`:

```bash
# Materializes a template by zfs-receiving a stream file. The cache key is the
# sha256 of the stream file (same scheme as the .sqsh path). Atomic via .tmp
# dataset; integrates with the same eviction sweep as ensure_template.
zfs::ensure_template_from_stream() {
    local -r stream="$1" sha="$2"
    local -r store=$(zfs::store_dataset)
    local -r template="${store}/${zfs_template_subdir}/${sha}"
    local -r tmp="${template}.tmp"
    local -r snap="${template}@${zfs_pristine_snap}"
    local i timeout=600

    zfs::sweep_templates 2> /dev/null || :    # no-op if Plan B not landed

    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        zfs::touch_template "${template}" 2> /dev/null || :
        printf "%s" "${template}"
        return
    fi

    if zfs create -p "$(dirname "${tmp}")" 2> /dev/null; then : ; fi   # parent
    # zfs recv into the .tmp name; on success, rename to final.
    if zfs receive -F "${tmp}" < "${stream}" 2> /dev/null; then
        # The received stream brings its own snapshot; rename the dataset and
        # alias the snapshot to @pristine if necessary.
        zfs rename "${tmp}" "${template}"
        if ! zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
            local recvd_snap
            recvd_snap=$(zfs list -H -t snapshot -o name -r -d 1 "${template}" | head -1)
            [ -n "${recvd_snap}" ] && zfs rename "${recvd_snap}" "${snap}"
        fi
        zfs set readonly=on "${template}"
        zfs::touch_template "${template}" 2> /dev/null || :
        printf "%s" "${template}"
        return
    fi

    # Receive failed — clean up our .tmp if any, then wait for another writer.
    zfs destroy -r "${tmp}" 2> /dev/null || :

    for ((i = 0; i < timeout; i++)); do
        if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
            printf "%s" "${template}"
            return
        fi
        sleep 1
    done
    common::err "Timed out waiting for stream receive: ${template}"
}
```

- [ ] **Step 1.2: Add `zfs::send_stream` for the export side**

Append to `src/storage_zfs.sh`:

```bash
# Sends a clone's @pristine snapshot (or the template it was cloned from) as a
# full zfs-send stream to a file. Container must exist and be a ZFS clone.
zfs::send_stream() {
    local -r name="$1" filename="$2"
    local -r store=$(zfs::store_dataset)
    local -r target="${store}/${name}"
    local origin

    if ! zfs list -H "${target}" > /dev/null 2>&1; then
        common::err "No such container: ${name}"
    fi

    origin=$(zfs get -H -o value origin "${target}")
    if [ -z "${origin}" ] || [ "${origin}" = "-" ]; then
        # Not a clone — must take a fresh snapshot of the live dataset.
        local snap="${target}@enroot-export-$$"
        zfs snapshot "${snap}"
        zfs send "${snap}" > "${filename}"
        zfs destroy "${snap}"
    else
        zfs send "${origin}" > "${filename}"
    fi
}
```

- [ ] **Step 1.3: Verify the recv side standalone**

```sh
# Manually create a stream file from an existing template:
zfs send tank/enroot/$USER/.templates/<some-sha>@pristine > /tmp/test.zfs
# Now feed it back in:
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         sha=$(sha256sum /tmp/test.zfs | awk "{print \$1}")
         zfs::ensure_template_from_stream /tmp/test.zfs "${sha}"'
zfs list -t all | grep "${sha:0:12}"
```

Expected: a template dataset and `@pristine` snapshot whose name contains the stream's sha.

- [ ] **Step 1.4: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::ensure_template_from_stream and zfs::send_stream"
```

---

### Task 2: Dispatch `runtime::create` on file extension

**Files:**
- Modify: `src/runtime.sh:391-430` (Plan A's `runtime::create`)

- [ ] **Step 2.1: Replace the body of `runtime::create` to dispatch on extension**

In `src/runtime.sh`, change `runtime::create` to:

```bash
runtime::create() {
    local image="$1" rootfs="$2"

    if [ -z "${image}" ]; then
        common::err "Invalid argument"
    fi
    image=$(common::realpath "${image}")
    if [ ! -f "${image}" ]; then
        common::err "No such file or directory: ${image}"
    fi

    case "${image}" in
        *.zfs)
            if ! zfs::enabled; then
                common::err ".zfs images require ENROOT_STORAGE_BACKEND=zfs"
            fi
            if [ -z "${rootfs}" ]; then
                rootfs=$(basename "${image%.zfs}")
            fi
            if [[ "${rootfs}" == */* ]]; then
                common::err "Invalid argument: ${rootfs}"
            fi
            zfs::checkenv
            local sha template
            sha=$(zfs::image_sha256 "${image}")
            template=$(zfs::ensure_template_from_stream "${image}" "${sha}")
            zfs::clone_container "${template}" "${rootfs}"
            ;;
        *)
            if ! unsquashfs -s "${image}" > /dev/null 2>&1; then
                common::err "Invalid image format: ${image} (expected .sqsh or .zfs)"
            fi
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
            ;;
    esac
}
```

- [ ] **Step 2.2: Verify `.zfs` create end-to-end**

```sh
# Round-trip via a stream:
/tmp/enroot/usr/bin/enroot create -n donor alpine.sqsh
zfs send tank/enroot/$USER/.templates/$(ls /srv/enroot/$USER/.templates)@pristine > /tmp/alpine.zfs
/tmp/enroot/usr/bin/enroot remove -f donor
zfs destroy -r tank/enroot/$USER/.templates    # nuke cache to force recv
/tmp/enroot/usr/bin/enroot create -n viareceive /tmp/alpine.zfs
ls /srv/enroot/$USER/viareceive/etc/os-release
/tmp/enroot/usr/bin/enroot remove -f viareceive
```

Expected: `os-release` readable; this exercised the `.zfs` recv path.

- [ ] **Step 2.3: Verify hard error on non-ZFS backend**

```sh
unset ENROOT_STORAGE_BACKEND
/tmp/enroot/usr/bin/enroot create -n bad /tmp/alpine.zfs && echo BAD || echo OK
```

Expected: `OK` (command failed with the "ENROOT_STORAGE_BACKEND=zfs" error message).

- [ ] **Step 2.4: Commit**

```sh
git add src/runtime.sh
git commit -s -m "Dispatch runtime::create on .sqsh vs .zfs extension"
```

---

### Task 3: Add `--format` to `enroot::export` and `runtime::export`

**Files:**
- Modify: `enroot.in:442-477` (CLI parsing)
- Modify: `enroot.in:163-172` (usage string for export)
- Modify: `src/runtime.sh:492-536` (`runtime::export`)

- [ ] **Step 3.1: Update the export usage block**

In `enroot.in:163-172`, add a `--format` row to the options:

```
   -o, --output  Name of the output image file (defaults to "NAME.sqsh" or "NAME.zfs")
   -f, --force   Overwrite an existing image
       --format  Output format: "sqsh" (default) or "zfs"
```

- [ ] **Step 3.2: Add `--format` parsing in `enroot::export`**

In `enroot.in:442-477`, add a `--format`/`--format=` case to the option parser, alongside the existing `-o` / `-f` cases. Pass the format through to `runtime::export` as a new third positional argument.

Concretely, change:

```bash
    runtime::export "${name}" "${filename}"
```

to:

```bash
    runtime::export "${name}" "${filename}" "${format:-sqsh}"
```

and ensure `format=` defaults to empty in the local declarations and is set by the parser when the flag is given.

- [ ] **Step 3.3: Branch `runtime::export` on format**

In `src/runtime.sh`, replace `runtime::export` (lines 492-536) with:

```bash
runtime::export() {
    local rootfs="$1" filename="$2" format="${3:-sqsh}"
    local exclude=()

    if [ -z "${rootfs}" ]; then
        common::err "Invalid argument"
    fi
    if [[ "${rootfs}" == */* ]]; then
        common::err "Invalid argument: ${rootfs}"
    fi

    case "${format}" in
        sqsh) ;;
        zfs)
            if ! zfs::enabled; then
                common::err "--format=zfs requires ENROOT_STORAGE_BACKEND=zfs"
            fi
            ;;
        *) common::err "Invalid format: ${format}" ;;
    esac

    if [ "${format}" = "sqsh" ]; then
        common::checkcmd mksquashfs
        local rootfs_path
        rootfs_path=$(common::realpath "${ENROOT_DATA_PATH}/${rootfs}")
        if [ ! -d "${rootfs_path}" ]; then
            common::err "No such file or directory: ${rootfs_path}"
        fi
        if [ -z "${filename}" ]; then
            filename="$(basename "${rootfs_path}").sqsh"
        fi
        filename=$(common::realpath "${filename}")
        if [ -e "${filename}" ]; then
            if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
                common::err "File already exists: ${filename}"
            else
                rm -f "${filename}"
            fi
        fi
        find "${rootfs_path}" -path "${rootfs_path}/dev/*" -o -perm 0000 -prune \( -empty -o -type d \) | readarray -t exclude
        if [ -d "${rootfs_path}${bundle_dir}" ]; then
            exclude+=("${rootfs_path}${bundle_dir}")
        fi
        if [ -f "${rootfs_path}${lock_file}" ]; then
            exclude+=("${rootfs_path}${lock_file}")
        fi
        common::log INFO "Creating squashfs filesystem..." NL
        mksquashfs "${rootfs_path}" "${filename}" -all-root ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
            ${ENROOT_SQUASH_OPTIONS} ${exclude[@]+-e "${exclude[@]}"} >&2
    else
        if [ -z "${filename}" ]; then
            filename="${rootfs}.zfs"
        fi
        filename=$(common::realpath "${filename}")
        if [ -e "${filename}" ]; then
            if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
                common::err "File already exists: ${filename}"
            else
                rm -f "${filename}"
            fi
        fi
        common::log INFO "Creating zfs send stream..." NL
        zfs::send_stream "${rootfs}" "${filename}"
    fi
}
```

- [ ] **Step 3.4: Verify `.sqsh` export still works (no regression)**

```sh
unset ENROOT_STORAGE_BACKEND
export ENROOT_DATA_PATH=$HOME/.local/share/enroot
/tmp/enroot/usr/bin/enroot create -n exp_test alpine.sqsh
/tmp/enroot/usr/bin/enroot export -o /tmp/regress.sqsh exp_test
unsquashfs -s /tmp/regress.sqsh > /dev/null && echo OK
/tmp/enroot/usr/bin/enroot remove -f exp_test
rm /tmp/regress.sqsh
```

Expected: `OK`.

- [ ] **Step 3.5: Verify `.zfs` export**

```sh
export ENROOT_STORAGE_BACKEND=zfs
export ENROOT_DATA_PATH=/srv/enroot/$USER
/tmp/enroot/usr/bin/enroot create -n exp_zfs alpine.sqsh
/tmp/enroot/usr/bin/enroot export --format=zfs -o /tmp/exp.zfs exp_zfs
file /tmp/exp.zfs   # should mention "ZFS"
/tmp/enroot/usr/bin/enroot create -n round_trip /tmp/exp.zfs
ls /srv/enroot/$USER/round_trip/etc/os-release
/tmp/enroot/usr/bin/enroot remove -f exp_zfs round_trip
```

Expected: file produced, round-trip create succeeds, os-release readable.

- [ ] **Step 3.6: Commit**

```sh
git add enroot.in src/runtime.sh
git commit -s -m "Add --format=zfs to enroot export"
```

---

### Task 4: Document Plan C as implemented

**Files:**
- Modify: `doc/zfs.md`

- [ ] **Step 4.1: Update status note**

Update `doc/zfs.md` to mark Plan C (`.zfs` file format) as landed.

- [ ] **Step 4.2: End-to-end smoke**

```sh
# Round-trip and bundle integrity:
/tmp/enroot/usr/bin/enroot create -n smoke alpine.sqsh
/tmp/enroot/usr/bin/enroot export --format=zfs smoke
/tmp/enroot/usr/bin/enroot export -o smoke.sqsh smoke           # sqsh export still works
/tmp/enroot/usr/bin/enroot remove -f smoke
/tmp/enroot/usr/bin/enroot create -n from_zfs smoke.zfs
/tmp/enroot/usr/bin/enroot create -n from_sqsh smoke.sqsh
diff <(ls /srv/enroot/$USER/from_zfs/etc) <(ls /srv/enroot/$USER/from_sqsh/etc) && echo SAME
/tmp/enroot/usr/bin/enroot remove -f from_zfs from_sqsh
rm smoke.zfs smoke.sqsh
```

Expected: `SAME` — both formats produce equivalent rootfs contents.

- [ ] **Step 4.3: Commit**

```sh
git add doc/zfs.md
git commit -s -m "Mark Plan C (.zfs format) as implemented"
```

---

## Self-review checklist

- [x] Spec coverage: `enroot create foo.zfs` (T2), `enroot export --format=zfs` (T3), hard error on non-ZFS host (T2.3, T3.3), no magic-byte sniffing — extension-only dispatch (T2.1).
- [x] Type consistency: `zfs::ensure_template_from_stream`, `zfs::send_stream` in T1 are referenced by T2, T3.
- [x] No placeholders.

## Execution Handoff

Same options as Plan A.
