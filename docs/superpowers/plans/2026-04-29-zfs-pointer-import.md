# ZFS Pointer-Format Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `enroot import docker://<ref>` produce a tiny magic-prefixed pointer file (instead of running `mksquashfs`) when the ZFS backend is active, so repeat imports of the same image hit the existing layer-keyed template cache and `enroot create` becomes a `O(zfs clone)` operation. Closes [#13](https://github.com/zeroae/enroot/issues/13).

**Architecture:** Replace the `.sqsh` artifact on ZFS-backend imports with a 1-KiB plain-text pointer file (magic line `enroot-zfs-image:v1`). Import populates the template cache via the existing `zfs::docker_install_from_layers` path (split into install + clone halves so the install half can be reused without an extra clone). `enroot create` magic-byte-sniffs the pointer, looks up the template by `image-config-sha256`, and clones — falling back to a registry re-pull if the template was evicted.

**Tech Stack:** Bash 4.2+, ZFS (OpenZFS 2.0+), Docker Registry v2 API, the existing `enroot-zfs-mount` cap_sys_admin helper. No new external dependencies.

**Spec:** [docs/superpowers/specs/2026-04-29-zfs-pointer-import-design.md](../specs/2026-04-29-zfs-pointer-import-design.md).

**Branch:** `feature/zfs-pointer-import` (already created and the spec is committed there).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/storage_zfs.sh` | All new functions: pointer file format I/O, pointer-aware import/create orchestrators, install-only refactor of `zfs::docker_install_from_layers`. ~150 lines added. |
| `src/runtime.sh` | Two minimal hooks: magic-byte sniff in `runtime::create`, branch in `runtime::import` for the pointer flow. ~30 lines added. |
| `enroot.in` | New `--format <pointer\|squashfs>` flag on `enroot import`. ~15 lines added. |
| `doc/zfs.md` | Documentation: pointer-format section, opt-out, eviction recovery, troubleshooting. |
| `conf/enroot.conf.in` | Document `ENROOT_ZFS_IMPORT_FORMAT`. |
| `Makefile` | Bump `VERSION` to `4.1.2.zfs.4`. |
| `pkg/deb/changelog` | New entry. |

No new files created. No `.c` changes. The `enroot-zfs-mount` helper is unchanged.

---

## Conventions and Project Notes

- All bash files use `set -euo pipefail; shopt -s lastpipe` and require **bash >= 4.2**.
- Functions are namespaced with `::` — `zfs::*`, `runtime::*`, `docker::*`, `common::*`.
- The project has **no automated test suite**. Verification is by syntax check (`bash -n`) on every commit, plus manual smoke tests on a ZFS-backed cluster (Tasks 11–12).
- All commits must be DCO-signed (`git commit -s`).
- `enroot.in` and `conf/enroot.conf.in` are templated by `sed` at build time. **Edit only the `.in` files.**
- Existing helper `zfs::docker_install_from_layers` lives at `src/storage_zfs.sh:587-636` and is the model for the new code paths.

---

## Task 1: Split `zfs::docker_install_from_layers` into install + clone halves

**Why:** The new pointer-import flow needs to populate the template *without* cloning to a user-named container. Today the function does both. Factoring out an install-only half preserves all existing call sites and gives the new flow a clean entry point.

**Files:**
- Modify: `src/storage_zfs.sh:587-636`

- [ ] **Step 1: Read the existing function**

```bash
sed -n '573,636p' src/storage_zfs.sh
```

Confirm the function takes `(cache_key, layer_count, unpriv, name)` and ends with `zfs::clone_container "${template}" "${name}"`.

- [ ] **Step 2: Apply the refactor**

Replace `src/storage_zfs.sh:573-636` (the entire `zfs::docker_install_from_layers` function and its leading comment block) with:

```bash
# Materializes the merged Docker rootfs into a ZFS template (cached by
# cache_key). Designed to be called from docker::load (or the pointer-import
# flow) AFTER docker::_prepare_layers has populated the cwd with extracted,
# whiteout-converted layer directories 0/, 1/, ..., N/.
#
# Inputs:
#   $1 cache_key   - sha256 of the image config blob (a stable per-image key)
#   $2 layer_count - the N from _prepare_layers (count of layer directories)
#   $3 unpriv      - "y" or "" — whether to enter a new user namespace
#
# Atomicity: races on the same cache_key are resolved via a per-key .tmp
# dataset lock; losers wait for @pristine. ENOSPC mid-merge destroys the
# .tmp so a retry can run.
zfs::_install_template_from_layers() {
    local -r cache_key="$1" layer_count="$2" unpriv="$3"
    local store template tmp snap mountpoint i=0
    store=$(zfs::store_dataset)
    template="${store}/${zfs_template_subdir}/${cache_key}"
    tmp="${template}.tmp"
    snap="${template}@${zfs_pristine_snap}"

    zfs::sweep_templates

    # Ensure the templates parent exists without auto-mounting it.
    zfs create -u "${store}/${zfs_template_subdir}" 2> /dev/null || :
    enroot-zfs-mount "${store}/${zfs_template_subdir}" 2> /dev/null || :

    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        common::log INFO "Reusing cached template ${cache_key:0:12}"
        zfs::touch_template "${template}"
    elif zfs create -u "${tmp}" 2> /dev/null; then
        if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
            zfs destroy "${tmp}" 2> /dev/null || :
            common::err "failed to mount docker template"
        fi
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        mkdir -p rootfs
        local merge_cmd
        merge_cmd="mount --make-rprivate / && mount -t overlay overlay -o lowerdir=0:$(seq -s: 1 "${layer_count}") rootfs &&
                   tar --numeric-owner -C rootfs/ --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${mountpoint}/' -xpf -"
        if ! enroot-nsenter ${unpriv:+--user} --mount --remap-root bash -c "${merge_cmd}"; then
            common::log WARN "Layer merge failed; evicting all warm templates and retrying"
            ENROOT_TEMPLATE_WARM_SECONDS=0 zfs::sweep_templates
            enroot-nsenter ${unpriv:+--user} --mount --remap-root bash -c "${merge_cmd}" \
              || { zfs destroy -r "${tmp}" 2> /dev/null || :; \
                   common::err "Failed to merge Docker layers into ZFS template even after evicting warm templates"; }
        fi
        enroot-zfs-mount --unmount "${tmp}" 2> /dev/null || :
        zfs rename "${tmp}" "${template}"
        enroot-zfs-mount "${template}" 2> /dev/null || :
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
        zfs::touch_template "${template}"
    else
        # Lost the race or stale .tmp — wait for @pristine.
        while ! zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; do
            sleep 1
            ((i++ < 600)) || common::err "Timed out waiting for Docker template: ${template}"
        done
    fi

    printf "%s" "${template}"
}

# Backwards-compatible wrapper: install the template (or wait for one) and
# clone it into the user-visible container name. This is what existing callers
# (docker::load) use.
zfs::docker_install_from_layers() {
    local -r cache_key="$1" layer_count="$2" unpriv="$3" name="$4"
    local template
    template=$(zfs::_install_template_from_layers "${cache_key}" "${layer_count}" "${unpriv}")
    zfs::clone_container "${template}" "${name}"
}
```

- [ ] **Step 3: Syntax-check the file**

```bash
bash -n src/storage_zfs.sh
```

Expected: no output (clean parse).

- [ ] **Step 4: Verify existing callers still match the signature**

```bash
grep -n "zfs::docker_install_from_layers\|zfs::_install_template_from_layers" src/storage_zfs.sh src/runtime.sh src/docker.sh
```

Expected: one call site in `src/docker.sh` (the existing `docker::load` path) still calling `zfs::docker_install_from_layers` with four arguments — signature unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: factor docker_install_from_layers into install + clone halves

The new pointer-import flow needs to populate a Docker template without
cloning it to a user-named container. Split the existing function into
zfs::_install_template_from_layers (install only, returns template path)
and a thin zfs::docker_install_from_layers wrapper that calls install +
zfs::clone_container so all existing callers keep working unchanged.

Pure refactor; no behavior change."
```

---

## Task 2: Add `zfs::template_exists` predicate

**Why:** The pointer-create hit path needs a cheap "is the template already cached?" check that doesn't go through `_install_template_from_layers` (which also runs the sweep, ensures parents, etc.). Single `zfs list` call.

**Files:**
- Modify: `src/storage_zfs.sh` (insert after `zfs::touch_template`, around line 51)

- [ ] **Step 1: Insert the function**

After the closing `}` of `zfs::touch_template` (currently `src/storage_zfs.sh:51`), insert:

```bash

# Returns 0 iff a fully-materialized template (with @pristine snapshot) exists
# for the given cache_key. Cheap predicate; does not run the eviction sweep.
zfs::template_exists() {
    local -r cache_key="$1"
    local store
    store=$(zfs::store_dataset)
    zfs list -H -t snapshot "${store}/${zfs_template_subdir}/${cache_key}@${zfs_pristine_snap}" > /dev/null 2>&1
}
```

- [ ] **Step 2: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

Expected: no output.

- [ ] **Step 3: Smoke-test the predicate against an existing template**

(Skip this step if not on a ZFS-backed dev host. Otherwise:)

```bash
# Find an existing template name (if any):
zfs list -H -d 1 -o name "$(zfs list -H -o name "${ENROOT_DATA_PATH}")/.templates" | tail -n +2 | head -1
# If output, e.g. tank/enroot/data/.templates/<sha>, then:
source src/storage_zfs.sh
zfs::template_exists "<that-sha>" && echo HIT || echo MISS
zfs::template_exists "deadbeef" && echo HIT || echo MISS
```

Expected: first call prints `HIT`, second prints `MISS`.

- [ ] **Step 4: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add zfs::template_exists predicate

Cheap (single zfs list -t snapshot) check used by the upcoming
create-from-pointer hit path to avoid running the full
_install_template_from_layers machinery on a guaranteed-hit case."
```

---

## Task 3: Add pointer file format helpers

**Why:** All four pointer I/O primitives (active-check, write, magic-detect, read) live together. Implement them as a unit so the next task can call them.

**Files:**
- Modify: `src/storage_zfs.sh` (insert after `zfs::image_sha256`, before `zfs::ensure_template`)

- [ ] **Step 1: Identify the insertion point**

```bash
grep -n "^zfs::image_sha256\|^zfs::ensure_template" src/storage_zfs.sh | head
```

Expected output: `zfs::image_sha256` at line 126, `zfs::ensure_template` at line 134. Insert the new block between lines 129 and 131 (after `image_sha256`'s closing `}`).

- [ ] **Step 2: Insert the helpers**

After the closing `}` of `zfs::image_sha256` (line 129), and before the comment `# Ensures a template dataset exists...` (line 131), insert:

```bash

# Pointer file format: a small plain-text artifact written by
# enroot import docker://... when the ZFS backend is active. It carries
# the stable image-config-sha256 (the cache key used by
# zfs::_install_template_from_layers) plus enough metadata to recover from
# template eviction by re-pulling from the registry. Filename stays .sqsh
# so pyxis (which feeds the path back to enroot create unchanged) is
# unaware of the format change. enroot create magic-byte-sniffs the first
# 19 bytes (`enroot-zfs-image:v1`) and dispatches to the pointer path.
readonly zfs_pointer_magic="enroot-zfs-image:v1"

# Returns 0 if the ZFS backend is active AND ENROOT_ZFS_IMPORT_FORMAT is
# unset or set to "pointer". Returns 1 otherwise (e.g. "squashfs" opt-out
# or dir backend). Callers gate the new pointer-import path on this.
zfs::pointer_format_active() {
    zfs::enabled || return 1
    case "${ENROOT_ZFS_IMPORT_FORMAT-pointer}" in
        pointer) return 0 ;;
        squashfs) return 1 ;;
        *) common::err "Invalid ENROOT_ZFS_IMPORT_FORMAT: ${ENROOT_ZFS_IMPORT_FORMAT} (expected pointer or squashfs)" ;;
    esac
}

# Returns 0 iff the file at $1 starts with the pointer magic line. Reads
# only the first 19 bytes; never reads beyond. Safe on regular files,
# squashfs blobs, ZFS send streams, and short/empty files.
zfs::is_pointer() {
    local -r path="$1"
    local head
    [ -f "${path}" ] || return 1
    head=$(dd if="${path}" bs=19 count=1 2> /dev/null) || return 1
    [ "${head}" = "${zfs_pointer_magic}" ]
}

# Atomically writes a pointer file at $1 with the given fields. Uses
# tmp + rename so partial writes never leave a half-formed pointer behind.
# All inputs are validated; refuses to write a pointer with a malformed
# config_sha or manifest_digest.
zfs::write_pointer() {
    local -r output="$1" config_sha="$2" manifest_digest="$3" arch="$4" uri="$5"
    local tmp imported

    [[ "${config_sha}" =~ ^[0-9a-f]{64}$ ]] \
      || common::err "zfs::write_pointer: invalid image-config-sha256: ${config_sha}"
    [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || common::err "zfs::write_pointer: invalid manifest-digest: ${manifest_digest}"
    [[ "${uri}" =~ ^docker:// ]] \
      || common::err "zfs::write_pointer: uri must start with docker://: ${uri}"

    imported=$(date -u +%FT%TZ)
    tmp="${output}.tmp.$$"
    {
        printf "%s\n" "${zfs_pointer_magic}"
        printf "image-config-sha256=%s\n" "${config_sha}"
        printf "manifest-digest=%s\n" "${manifest_digest}"
        printf "arch=%s\n" "${arch}"
        printf "uri=%s\n" "${uri}"
        printf "imported=%s\n" "${imported}"
    } > "${tmp}" || { rm -f "${tmp}" 2> /dev/null || :; common::err "Failed to write pointer ${output}"; }
    mv -f "${tmp}" "${output}"
}

# Parses a pointer file and prints the recognized fields, one per line, as
# KEY=VALUE pairs (suitable for `eval`-style consumption — the values
# themselves are validated against strict regexes so no shell-metachar
# escape is needed). Errors if the magic line is missing or any required
# field fails validation.
zfs::read_pointer() {
    local -r path="$1"
    local line key value config_sha= manifest_digest= arch= uri= imported=

    common::read -r line < "${path}"
    [ "${line}" = "${zfs_pointer_magic}" ] \
      || common::err "Not a ZFS pointer file: ${path}"

    while IFS='=' common::read -r key value; do
        case "${key}" in
            image-config-sha256) config_sha="${value}" ;;
            manifest-digest)     manifest_digest="${value}" ;;
            arch)                arch="${value}" ;;
            uri)                 uri="${value}" ;;
            imported)            imported="${value}" ;;
            "")                  : ;;  # blank line
            *) : ;;                    # forward-compatible: ignore unknown
        esac
    done < <(tail -n +2 "${path}")

    [[ "${config_sha}" =~ ^[0-9a-f]{64}$ ]] \
      || common::err "Pointer ${path} missing/invalid image-config-sha256"
    [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || common::err "Pointer ${path} missing/invalid manifest-digest"
    [[ "${arch}" =~ ^[a-z0-9_-]+$ ]] \
      || common::err "Pointer ${path} missing/invalid arch"
    [[ "${uri}" =~ ^docker:// ]] \
      || common::err "Pointer ${path} missing/invalid uri"

    printf "image-config-sha256=%s\n" "${config_sha}"
    printf "manifest-digest=%s\n"     "${manifest_digest}"
    printf "arch=%s\n"                "${arch}"
    printf "uri=%s\n"                 "${uri}"
    printf "imported=%s\n"            "${imported}"
}
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

Expected: no output.

- [ ] **Step 4: Smoke-test write/read round-trip**

```bash
source src/common.sh
source src/storage_zfs.sh
out=$(mktemp)
zfs::write_pointer "${out}" \
  "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" \
  "sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789" \
  "arm64" \
  "docker://registry-1.docker.io/library/ubuntu:24.04"
echo --- pointer file ---
cat "${out}"
echo --- magic check ---
zfs::is_pointer "${out}" && echo IS_POINTER || echo NOT_POINTER
echo --- read parse ---
zfs::read_pointer "${out}"
echo --- negative checks ---
zfs::is_pointer /etc/hostname && echo BUG_HOSTNAME || echo OK_NOT_POINTER
zfs::is_pointer /nonexistent && echo BUG_NX || echo OK_MISSING
rm -f "${out}"
```

Expected output: pointer file with 6 lines starting with the magic line; `IS_POINTER`; `read_pointer` prints all 5 KEY=VALUE lines with the right values; `OK_NOT_POINTER`; `OK_MISSING`.

- [ ] **Step 5: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add pointer file format helpers

Adds zfs::pointer_format_active, zfs::is_pointer, zfs::write_pointer,
zfs::read_pointer and the zfs_pointer_magic constant. These are the I/O
primitives for the new pointer-format import path; the magic line
'enroot-zfs-image:v1' is what enroot create magic-byte-sniffs to
distinguish a pointer from a real .sqsh file.

write_pointer writes atomically (tmp + rename) and validates each field;
read_pointer validates against strict regexes before printing the
KEY=VALUE pairs, so callers can eval the output without escaping."
```

---

## Task 4: Add `zfs::import_docker_pointer`

**Why:** This is the import-side orchestrator. It does what `docker::import` does up to the point of `mksquashfs`, then writes a pointer instead. Reuses `docker::_prepare_layers` (which already does manifest fetch + layer pull + extract + whiteout-conversion + config blob materialization) and the new `zfs::_install_template_from_layers` from Task 1.

**Files:**
- Modify: `src/storage_zfs.sh` (append at end of file, after `zfs::docker_install_from_layers`)
- Read for reference: `src/docker.sh:439-486` (`docker::import`) and `src/docker.sh:488-556` (`docker::load`).

- [ ] **Step 1: Read the model functions**

```bash
sed -n '439,556p' src/docker.sh
```

Confirm `docker::_prepare_layers` returns two lines on stdout (config sha + layer count) and that `docker::load` already invokes `zfs::docker_install_from_layers` for the ZFS direct-create case.

- [ ] **Step 2: Append the new function**

Append at the end of `src/storage_zfs.sh`:

```bash

# Import flow for docker:// URIs when the ZFS backend is active and the
# pointer format is selected. Pulls layers (via docker::_prepare_layers),
# fetches the manifest digest (via docker::digest), populates the
# layer-keyed template cache (via zfs::_install_template_from_layers),
# and writes a pointer file at output_path. Skips mksquashfs entirely.
#
# Counterpart of docker::import for the pointer flow. Modeled on
# docker::load (which uses the same layer-pull + template-install
# combination for direct enroot create docker://X).
#
# Inputs:
#   $1 uri          - docker://[USER@]REGISTRY[:PORT]/IMAGE[:TAG]
#   $2 output_path  - where to write the pointer (caller pre-validated)
#   $3 arch         - already debarch-normalized
zfs::import_docker_pointer() {
    local -r uri="$1" output_path="$2" arch="$3"
    local user= registry= image= tag= tmpdir= config= layer_count= unpriv=
    local manifest_digest=

    common::checkcmd curl grep awk jq parallel tar "${ENROOT_GZIP_PROGRAM}" find zstd

    docker::_parse_uri "${uri}" \
      | { common::read -r user; common::read -r registry; common::read -r image; common::read -r tag; }

    # Fetch the manifest digest first (cheap HEAD on the manifest URL).
    # We do this before the expensive layer pull so a registry-side
    # mismatch fails fast.
    manifest_digest=$(docker::digest "${uri}" "${arch}")
    [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || common::err "registry returned invalid manifest digest: ${manifest_digest}"

    # Create a temporary directory and chdir to it (same pattern as
    # docker::import / docker::load — _prepare_layers writes layer
    # directories into the cwd).
    trap 'common::rmall "${tmpdir}" 2> /dev/null; rm -f "${token_dir}"/*.$$ 2> /dev/null' EXIT
    tmpdir=$(common::mktmpdir enroot)
    common::chdir "${tmpdir}"

    ENROOT_SET_USER_XATTRS=y docker::_prepare_layers "${user}" "${registry}" "${image}" "${tag}" "${arch}" \
      | { common::read -r config; common::read -r layer_count; }

    # Running as a non-root user requires entering a user namespace for the
    # tar-over-overlayfs merge inside _install_template_from_layers (same
    # logic as docker::load).
    if [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    zfs::_install_template_from_layers "${config}" "${layer_count}" "${unpriv}" > /dev/null

    zfs::write_pointer "${output_path}" "${config}" "${manifest_digest}" "${arch}" "${uri}"
}
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

Expected: no output.

- [ ] **Step 4: Confirm dependencies are reachable**

The function calls `docker::_parse_uri`, `docker::digest`, `docker::_prepare_layers`, `common::checkcmd`, `common::read`, `common::rmall`, `common::mktmpdir`, `common::chdir`, `common::err`, and the new `zfs::_install_template_from_layers` and `zfs::write_pointer`. Verify each is defined somewhere:

```bash
for fn in docker::_parse_uri docker::digest docker::_prepare_layers \
          common::checkcmd common::read common::rmall common::mktmpdir \
          common::chdir common::err \
          zfs::_install_template_from_layers zfs::write_pointer; do
    if grep -q "^${fn}\b\|^${fn}(" src/*.sh; then
        echo OK "${fn}"
    else
        echo MISSING "${fn}"
    fi
done
```

Expected: all 11 print `OK`. (`token_dir` is a global set by `docker::_authenticate`; it's referenced by `docker::digest` and friends already, so we inherit it via the same scope.)

- [ ] **Step 5: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add zfs::import_docker_pointer

The import-side orchestrator for the new pointer flow. Pulls docker
layers via docker::_prepare_layers, captures the manifest digest via
docker::digest, populates the template cache via the new
zfs::_install_template_from_layers, and writes a pointer file. Skips
mksquashfs entirely — that is the dominant cost the new format
eliminates.

Modeled on docker::load (which already uses the same layer-pull +
template-install combination for direct enroot create docker://)."
```

---

## Task 5: Add `zfs::create_from_pointer`

**Why:** This is the create-side orchestrator. Hits the cheap predicate first; on hit, clones immediately. On miss (template was evicted by the warm/cold sweep), recovers by re-running the import flow against the pointer's URI.

**Files:**
- Modify: `src/storage_zfs.sh` (append at end)

- [ ] **Step 1: Append the function**

Append at the end of `src/storage_zfs.sh`:

```bash

# Create flow for a ZFS pointer file. Reads the pointer, then either:
# (a) clones an already-cached template on hit, or
# (b) re-pulls from the pointer's URI to repopulate an evicted template,
#     then clones. The freshly-pulled image-config-sha256 must match the
#     pointer's claim — otherwise the registry tag has been republished
#     and the pointer is stale.
#
# Inputs:
#   $1 pointer_path  - validated pointer file (caller already passed
#                      zfs::is_pointer)
#   $2 name          - user-visible container name (no slashes)
zfs::create_from_pointer() {
    local -r pointer_path="$1" name="$2"
    local fresh_config_sha
    local image_config_sha256= manifest_digest= arch= uri= imported=
    local store template

    zfs::checkenv

    # Parse the pointer (read_pointer validates each field against strict
    # regexes; safe to eval).
    eval "$(zfs::read_pointer "${pointer_path}")"

    if zfs::template_exists "${image_config_sha256}"; then
        store=$(zfs::store_dataset)
        template="${store}/${zfs_template_subdir}/${image_config_sha256}"
        zfs::touch_template "${template}"
        zfs::clone_container "${template}" "${name}"
        return
    fi

    # Eviction recovery: re-pull from the registry. The new
    # image-config-sha256 must match the pointer's claim; mismatch means
    # the upstream tag has been republished, which we surface as a clear
    # error rather than silently cloning a different image.
    common::log INFO "Template ${image_config_sha256:0:12} evicted; re-pulling from ${uri}"
    fresh_config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}")
    if [ "${fresh_config_sha}" != "${image_config_sha256}" ]; then
        common::err "Pointer ${pointer_path} references image-config-sha256 ${image_config_sha256:0:12}, but ${uri} now resolves to ${fresh_config_sha:0:12}. Delete and re-import."
    fi

    store=$(zfs::store_dataset)
    template="${store}/${zfs_template_subdir}/${image_config_sha256}"
    zfs::clone_container "${template}" "${name}"
}

# Internal helper used by both the import flow's recovery path and (via
# zfs::import_docker_pointer) the main import flow. Pulls layers and
# installs the template; prints the resolved image-config-sha256 so the
# caller can validate it. Does NOT write a pointer file.
zfs::_pull_and_install_template() {
    local -r uri="$1" arch="$2"
    local user= registry= image= tag= tmpdir= config= layer_count= unpriv=

    common::checkcmd curl grep awk jq parallel tar "${ENROOT_GZIP_PROGRAM}" find zstd

    docker::_parse_uri "${uri}" \
      | { common::read -r user; common::read -r registry; common::read -r image; common::read -r tag; }

    trap 'common::rmall "${tmpdir}" 2> /dev/null; rm -f "${token_dir}"/*.$$ 2> /dev/null' EXIT
    tmpdir=$(common::mktmpdir enroot)
    common::chdir "${tmpdir}"

    ENROOT_SET_USER_XATTRS=y docker::_prepare_layers "${user}" "${registry}" "${image}" "${tag}" "${arch}" \
      | { common::read -r config; common::read -r layer_count; }

    if [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    zfs::_install_template_from_layers "${config}" "${layer_count}" "${unpriv}" > /dev/null

    printf "%s" "${config}"
}
```

- [ ] **Step 2: Refactor `zfs::import_docker_pointer` to share the puller**

Now that `zfs::_pull_and_install_template` exists, dedupe `zfs::import_docker_pointer` to use it. Replace the body of `zfs::import_docker_pointer` (everything between `zfs::import_docker_pointer() {` and the matching `}`) with:

```bash
    local -r uri="$1" output_path="$2" arch="$3"
    local config_sha= manifest_digest=

    # Fetch the manifest digest first (cheap HEAD; fails fast on bad URI).
    manifest_digest=$(docker::digest "${uri}" "${arch}")
    [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || common::err "registry returned invalid manifest digest: ${manifest_digest}"

    config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}")

    zfs::write_pointer "${output_path}" "${config_sha}" "${manifest_digest}" "${arch}" "${uri}"
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

Expected: no output.

- [ ] **Step 4: Verify dispatch correctness**

```bash
grep -nE "zfs::(import_docker_pointer|create_from_pointer|_pull_and_install_template|_install_template_from_layers|template_exists|read_pointer|write_pointer|is_pointer|pointer_format_active)" src/storage_zfs.sh
```

Expected: each function defined exactly once and called from at least one site downstream of its definition.

- [ ] **Step 5: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add zfs::create_from_pointer + dedupe puller

create_from_pointer is the create-side orchestrator: hit path is just
template_exists + clone_container (subseconds); miss path re-pulls from
the pointer's URI and validates the freshly-resolved
image-config-sha256 matches the pointer's claim (tag-republish detection).

Factor the layer-pull-and-install into zfs::_pull_and_install_template
shared by both import_docker_pointer and the recovery path."
```

---

## Task 6: Wire `runtime::create` to magic-sniff and dispatch

**Why:** This is the entry point all `enroot create` invocations flow through. A single magic-byte sniff at the top intercepts pointer files and routes them; everything else (real `.sqsh`, `.zfs` send-stream, dir backend) falls through unchanged.

**Files:**
- Modify: `src/runtime.sh:429-471` (`runtime::create`)

- [ ] **Step 1: Read the current dispatcher**

```bash
sed -n '429,471p' src/runtime.sh
```

Confirm the structure: realpath + exists check, then a `case "${image}"` with `*.zfs` and `*` branches.

- [ ] **Step 2: Insert the magic-byte sniff**

In `src/runtime.sh`, find the line (`src/runtime.sh:441`):

```bash
    case "${image}" in
```

Replace the lines from `image=$(common::realpath ...)` through the `if [ ! -f "${image}" ]` block (currently `src/runtime.sh:436-440`) and the `case` opener so the result reads:

```bash
    image=$(common::realpath "${image}")
    if [ ! -f "${image}" ]; then
        common::err "No such file or directory: ${image}"
    fi

    # Pointer-format .sqsh (ZFS backend): magic-prefixed file produced by
    # `enroot import docker://` when ENROOT_ZFS_IMPORT_FORMAT=pointer
    # (default on ZFS backend). Detect via magic bytes — filename is still
    # .sqsh by convention so pyxis is unaware of the format.
    if zfs::is_pointer "${image}"; then
        if ! zfs::enabled; then
            common::err "${image} is a ZFS pointer file; ENROOT_STORAGE_BACKEND=zfs is required to use it"
        fi
        if [ -z "${rootfs}" ]; then
            rootfs=$(basename "${image%.sqsh}")
        fi
        if [[ "${rootfs}" == */* ]]; then
            common::err "Invalid argument: ${rootfs}"
        fi
        zfs::create_from_pointer "${image}" "${rootfs}"
        return
    fi

    case "${image}" in
```

The lines after `case "${image}" in` are unchanged.

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/runtime.sh
```

Expected: no output.

- [ ] **Step 4: Verify the existing `.zfs` branch and squashfs branch are still reachable**

```bash
sed -n '441,490p' src/runtime.sh
```

Expected: dispatcher now opens with the `if zfs::is_pointer` block, then the unchanged `case "${image}" in` with `*.zfs)` and `*)` branches.

- [ ] **Step 5: Commit**

```bash
git add src/runtime.sh
git commit -s -m "runtime: dispatch ZFS pointer files in runtime::create

Adds a magic-byte sniff (zfs::is_pointer) at the top of runtime::create.
Pointer files are routed to zfs::create_from_pointer; everything else
(real .sqsh, .zfs send-stream, dir backend) falls through unchanged.

Pointer files used on a node without ENROOT_STORAGE_BACKEND=zfs error
out cleanly — they cannot be 'extracted' the way a real squashfs can,
so we surface that explicitly rather than letting unsquashfs fail with
a confusing message."
```

---

## Task 7: Wire `runtime::import` to dispatch to pointer flow

**Why:** When the ZFS backend is active and the format selector is `pointer` (default), `enroot import docker://X` should call the new `zfs::import_docker_pointer` instead of `docker::import`. The `--format=squashfs` opt-out and the `ENROOT_ZFS_IMPORT_FORMAT` env var both flow through `zfs::pointer_format_active`.

**Files:**
- Modify: `src/runtime.sh:525-545` (`runtime::import`)

- [ ] **Step 1: Read the current import dispatcher**

```bash
sed -n '525,545p' src/runtime.sh
```

- [ ] **Step 2: Add filename defaulting for pointer files and the new branch**

Replace `runtime::import` (currently `src/runtime.sh:525-545`) with:

```bash
runtime::import() {
    local -r uri="$1"
    local filename="$2"
    local arch="$3"

    # Use the host architecture as the default.
    if [ -z "${arch}" ]; then
        arch=$(uname -m)
    fi

    # Import a container image from the URI specified.
    case "${uri}" in
    docker://*)
        if zfs::pointer_format_active; then
            # ZFS pointer-format import: write a small magic-prefixed
            # pointer file alongside populating the template cache.
            # Filename defaulting follows docker::import (caller may
            # leave $filename empty); we still produce a .sqsh-named
            # file so pyxis hands it back to enroot create unchanged.
            if [ -z "${filename}" ]; then
                # Mirror docker::import's filename derivation. Re-parse
                # the URI here to compute the default name.
                local _user= _registry= _image= _tag=
                docker::_parse_uri "${uri}" \
                  | { common::read -r _user; common::read -r _registry; common::read -r _image; common::read -r _tag; }
                if [ -n "${arch}" ]; then
                    arch=$(common::debarch "${arch}")
                fi
                local _display_image="${_image}"
                if [[ "${_registry}" == "registry-1.docker.io" && "${_image}" == library/* ]]; then
                    _display_image="${_image#library/}"
                fi
                filename="${_display_image////+}${_tag:++${_tag}}.sqsh"
            else
                if [ -n "${arch}" ]; then
                    arch=$(common::debarch "${arch}")
                fi
            fi
            filename=$(common::realpath "${filename}")
            if [ -e "${filename}" ]; then
                common::err "File already exists: ${filename}"
            fi
            zfs::import_docker_pointer "${uri}" "${filename}" "${arch}"
        else
            docker::import "${uri}" "${filename}" "${arch}"
        fi
        ;;
    dockerd://* | podman://*)
        docker::daemon::import "${uri}" "${filename}" "${arch}" ;;
    zfs://*)
        zfs::import_uri "${uri}" "${filename}" ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
}
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/runtime.sh
```

Expected: no output.

- [ ] **Step 4: Smoke-test the dispatcher selection logic**

```bash
( source src/common.sh; source src/storage_zfs.sh
  ENROOT_STORAGE_BACKEND=dir; zfs::pointer_format_active && echo BUG_DIR || echo OK_DIR
  ENROOT_STORAGE_BACKEND=zfs; ENROOT_DATA_PATH=/tmp; export ENROOT_STORAGE_BACKEND ENROOT_DATA_PATH
  unset ENROOT_ZFS_IMPORT_FORMAT
  zfs::pointer_format_active && echo OK_DEFAULT || echo BUG_DEFAULT
  ENROOT_ZFS_IMPORT_FORMAT=squashfs zfs::pointer_format_active && echo BUG_OPTOUT || echo OK_OPTOUT
  ENROOT_ZFS_IMPORT_FORMAT=pointer  zfs::pointer_format_active && echo OK_EXPLICIT || echo BUG_EXPLICIT
)
```

Expected: `OK_DIR`, `OK_DEFAULT`, `OK_OPTOUT`, `OK_EXPLICIT`.

- [ ] **Step 5: Commit**

```bash
git add src/runtime.sh
git commit -s -m "runtime: dispatch ZFS pointer-format imports

When ENROOT_STORAGE_BACKEND=zfs and ENROOT_ZFS_IMPORT_FORMAT is unset
or 'pointer' (the default), enroot import docker://... now calls
zfs::import_docker_pointer instead of docker::import — writing a small
pointer file and skipping mksquashfs.

Setting ENROOT_ZFS_IMPORT_FORMAT=squashfs preserves the legacy
behavior. dir backend is unaffected."
```

---

## Task 8: Add `--format` CLI flag in `enroot.in`

**Why:** Per-invocation override of the import format. Honors and overrides `ENROOT_ZFS_IMPORT_FORMAT` for that one call. Update help text.

**Files:**
- Modify: `enroot.in:359-427` (the `enroot::import` argument parser)
- Modify: `enroot.in:165-200` (the `import` help block)

- [ ] **Step 1: Read the current argument parser**

```bash
sed -n '359,427p' enroot.in
```

- [ ] **Step 2: Add the `--format` flag**

In `enroot::import`, immediately before the `--zfs-recv` case (currently `enroot.in:394`), insert:

```bash
        -f|--format)
            [ -z "${2-}" ] && enroot::usage import 1
            export ENROOT_ZFS_IMPORT_FORMAT="$2"
            shift 2
            ;;
        --format=*)
            [ -z "${1#*=}" ] && enroot::usage import 1
            export ENROOT_ZFS_IMPORT_FORMAT="${1#*=}"
            shift
            ;;
```

The choice of `-f` short form is consistent with `enroot::load`'s existing `-f|--force` only on `load`, not `import`, so there's no clash. (Verify: `grep -n "\\-f|" enroot.in | grep import` → no match.)

- [ ] **Step 3: Update the help block**

In `enroot::usage` for the `import` subcommand (around `enroot.in:165-200`), find the `-o, --output` line and add a `-f, --format` line directly above or below it. Locate via:

```bash
grep -n "\-o, --output" enroot.in | head
```

Then in the import-specific usage block (around line 173 and 192), add (using the same 12-column padding the other flags use):

```
		   -f, --format  Output format ("pointer" or "squashfs"). On the ZFS backend, "pointer" (default) writes a small pointer file and populates the template cache; "squashfs" forces a real .sqsh. Ignored on the dir backend.
```

- [ ] **Step 4: Syntax-check the templated `enroot` script**

`enroot.in` is templated; build it:

```bash
make mostlyclean
make enroot
bash -n enroot
```

Expected: clean parse.

- [ ] **Step 5: Verify the flag is parsed**

```bash
./enroot import --format=squashfs --help 2>&1 | head -20
./enroot import -f pointer --help 2>&1 | head -20
```

Expected: both invocations enter the import subcommand and print its usage (any error message indicates a parser bug; the `--help` causes early exit so we won't actually do an import).

- [ ] **Step 6: Commit**

```bash
git add enroot.in
git commit -s -m "enroot: add --format flag to enroot import

Per-invocation override of the import format (pointer vs squashfs).
Sets ENROOT_ZFS_IMPORT_FORMAT for the rest of the call. Same effect as
the env var, but expressed at the CLI."
```

---

## Task 9: Document the new behavior

**Why:** `doc/zfs.md` is the design and ops reference for the ZFS backend. Operators reading it need to know what a pointer file is, when it's produced, how to opt out, and how eviction recovery works. `conf/enroot.conf.in` documents the env var.

**Files:**
- Modify: `doc/zfs.md`
- Modify: `conf/enroot.conf.in`

- [ ] **Step 1: Locate the right section in `doc/zfs.md`**

```bash
grep -n "^##\|^###" doc/zfs.md | head -30
```

Find the section that documents the import flow / template cache. Add a new top-level section `## Pointer-format import (default on ZFS backend)` immediately after that section.

- [ ] **Step 2: Write the new section**

Insert the following section into `doc/zfs.md` at the location identified in Step 1:

```markdown
## Pointer-format import (default on ZFS backend)

When `ENROOT_STORAGE_BACKEND=zfs`, `enroot import docker://<ref>` writes a
small (< 1 KiB) **pointer file** instead of a real squashfs image. The pointer
carries the docker manifest digest and the `image-config-sha256` (the same
stable cache key used by direct `enroot create docker://<ref>`). `enroot
create` reads the pointer and clones the cached template — `O(zfs clone)`,
subseconds — instead of running `unsquashfs`. Repeat imports of the same
image hit the existing template cache, even though each `enroot import`
otherwise produces a non-deterministic squashfs (timestamps and per-build
metadata leak through `mksquashfs`).

Pointer files are recognizable by their first line:

```
enroot-zfs-image:v1
image-config-sha256=<64-hex>
manifest-digest=sha256:<64-hex>
arch=arm64
uri=docker://registry-1.docker.io/library/ubuntu:24.04
imported=2026-04-29T18:23:11Z
```

Pyxis treats the file as opaque (writes to a per-uid runtime dir, deletes it
after `enroot create`), so the format change is invisible to pyxis.

### Opting out

Set `ENROOT_ZFS_IMPORT_FORMAT=squashfs` in the environment or the config
file to force the legacy behavior (real `.sqsh`). The same effect is reachable
per-invocation via `enroot import --format=squashfs docker://<ref>`. Use this
when you need a portable squashfs artifact (e.g. to copy across nodes that
don't share a ZFS pool).

### Eviction recovery

Templates are reaped by the existing warm/cold sweep on each `enroot create`
(see `ENROOT_TEMPLATE_WARM_SECONDS` and `ENROOT_TEMPLATE_PRESSURE_THRESHOLD`).
If the pointer's referenced template was evicted between import and create,
`enroot create` re-pulls from the pointer's `uri` and validates that the
freshly-resolved `image-config-sha256` still matches the pointer's claim. If
the upstream tag has been republished (different config sha), `enroot create`
errors out with a "delete and re-import" message — silently substituting a
different image would defeat the whole point of content-addressing the cache.

### Cross-node portability

A pointer file references a template that lives in the importing node's ZFS
pool. Pointers are not portable to other nodes (the referenced template will
not exist there). For multi-node workflows:

- Per-node pointer imports — let each node import its own pointer; the cache
  and the work both stay local. This is what pyxis already does.
- `--format=squashfs` — produce a real squashfs, copy it.
- The existing `zfs://<host>/<name>` send-stream transport — push a populated
  template to a peer over SSH.
```

- [ ] **Step 3: Document the env var in `conf/enroot.conf.in`**

```bash
grep -n "ENROOT_TEMPLATE_WARM_SECONDS\|ENROOT_STORAGE_BACKEND" conf/enroot.conf.in | head
```

Find the section where ZFS-backend knobs are documented (likely near `ENROOT_TEMPLATE_WARM_SECONDS`). Add immediately after it:

```
#ENROOT_ZFS_IMPORT_FORMAT  pointer
# Format produced by `enroot import docker://...` when the ZFS storage
# backend is active. "pointer" (default) writes a small pointer file
# and populates the template cache as a side effect — repeat imports
# of the same image hit the cache. "squashfs" forces a legacy real
# .sqsh artifact. Ignored on the dir backend. Override per-invocation
# with `enroot import --format=...`.
```

- [ ] **Step 4: Verify the templated config still builds**

```bash
make mostlyclean
make conf/enroot.conf
grep -n "ENROOT_ZFS_IMPORT_FORMAT" conf/enroot.conf
```

Expected: the env var documentation appears in the built config.

- [ ] **Step 5: Commit**

```bash
git add doc/zfs.md conf/enroot.conf.in
git commit -s -m "doc: pointer-format import section in doc/zfs.md

Documents the default-on pointer flow, the squashfs opt-out, eviction
recovery semantics, and cross-node portability tradeoffs. Also adds an
ENROOT_ZFS_IMPORT_FORMAT entry to conf/enroot.conf.in."
```

---

## Task 10: Bump version and changelog

**Why:** This is the v4.1.2.zfs.4 line. Mirrors the pattern from the previous three zfs.* releases.

**Files:**
- Modify: `Makefile:16`
- Modify: `pkg/deb/changelog`

- [ ] **Step 1: Bump version**

In `Makefile`, change line 16 from:

```
VERSION       := 4.1.2.zfs.3
```

to:

```
VERSION       := 4.1.2.zfs.4
```

- [ ] **Step 2: Add a changelog entry**

Prepend a new entry at the top of `pkg/deb/changelog`:

```
#PACKAGE# (4.1.2.zfs.4-1) UNRELEASED; urgency=medium

  * Add ZFS pointer-format import (default on ZFS backend). `enroot
    import docker://<ref>` now writes a small pointer file and populates
    the layer-keyed template cache, skipping `mksquashfs` entirely. Repeat
    imports of the same image (e.g. pyxis-driven Slurm jobs) hit the cache
    and `enroot create` becomes O(zfs clone). `--format=squashfs` or
    `ENROOT_ZFS_IMPORT_FORMAT=squashfs` preserves the legacy behavior
    (issue #13).

 -- #USERNAME# <#EMAIL#>  Wed, 29 Apr 2026 21:00:00 +0000

```

(Leave a blank line between the new entry and the previous `(4.1.2.zfs.3-1)` entry.)

- [ ] **Step 3: Verify**

```bash
grep -n "^VERSION" Makefile
head -10 pkg/deb/changelog
```

Expected: VERSION is `4.1.2.zfs.4`; changelog top entry is the new `4.1.2.zfs.4-1` block.

- [ ] **Step 4: Commit**

```bash
git add Makefile pkg/deb/changelog
git commit -s -m "Release 4.1.2.zfs.4: ZFS pointer-format import (issue #13)

Bumps version and adds the changelog entry."
```

---

## Task 11: Manual end-to-end smoke test on a ZFS-backed cluster

**Why:** The project has no automated tests. This task is the contract: the implementation isn't done until each smoke check passes. Each scenario maps to an acceptance criterion in the spec (§9).

**Prerequisites:**
- Test node running ZFS with `${pool}/${dataset}` mounted at `${ENROOT_DATA_PATH}`.
- `enroot+caps` from this branch installed (so `enroot-zfs-mount` has `cap_sys_admin+pe`).
- ZFS delegation set per `doc/zfs.md` (`create,mount,clone,destroy,snapshot,rename,promote,receive,readonly,hold,release,canmount,userprop`).
- `/etc/enroot/enroot.conf` has `ENROOT_STORAGE_BACKEND zfs` and `ENROOT_DATA_PATH <path>`.

- [ ] **Step 1: Build the .deb on the dev box**

```bash
make clean
CPPFLAGS="-DALLOW_SPECULATION -DINHERIT_FDS" make deb
ls dist/
```

Expected: `dist/enroot_4.1.2.zfs.4-1_arm64.deb` and `dist/enroot+caps_4.1.2.zfs.4-1_arm64.deb`.

- [ ] **Step 2: Install on the test node**

(Adapt to your node-distribution mechanism.)

```bash
scp dist/enroot{,+caps}_4.1.2.zfs.4-1_arm64.deb spark-f2ff:/tmp/
ssh spark-f2ff sudo dpkg -i /tmp/enroot_4.1.2.zfs.4-1_arm64.deb /tmp/enroot+caps_4.1.2.zfs.4-1_arm64.deb
```

- [ ] **Step 3: Pointer import smoke**

On the test node, as a regular user:

```bash
rm -f /tmp/u.sqsh
enroot import docker://ubuntu:24.04 -o /tmp/u.sqsh
ls -la /tmp/u.sqsh
head -1 /tmp/u.sqsh
file /tmp/u.sqsh
sudo zfs list -H -d 1 -o name "$(zfs list -H -o name "${ENROOT_DATA_PATH}")/.templates"
```

Expected: file size < 4 KiB; first line is `enroot-zfs-image:v1`; `file(1)` reports ASCII text; templates list contains exactly one new dataset.

- [ ] **Step 4: Pointer create smoke (cache hit)**

```bash
rm -rf "${ENROOT_DATA_PATH}/u1" 2> /dev/null || true
time enroot create -n u1 /tmp/u.sqsh
sudo zfs list "$(zfs list -H -o name "${ENROOT_DATA_PATH}")/u1"
enroot start u1 cat /etc/os-release | head -2
enroot remove -f u1
```

Expected: `enroot create` completes in well under 1 s (real time); `u1` is a ZFS dataset (not a regular directory); `cat /etc/os-release` prints `PRETTY_NAME="Ubuntu 24.04..."`.

- [ ] **Step 5: Repeat-import idempotence**

```bash
rm -f /tmp/u.sqsh
enroot import docker://ubuntu:24.04 -o /tmp/u.sqsh
sudo zfs list -H -d 1 -o name "$(zfs list -H -o name "${ENROOT_DATA_PATH}")/.templates"
```

Expected: the templates list is **unchanged** — no new template was created (the second import hit the cache).

- [ ] **Step 6: Pyxis end-to-end (the issue's repro)**

From the Slurm controller / login node:

```bash
srun --container-image=docker://ubuntu:24.04 cat /etc/os-release
time srun --container-image=docker://ubuntu:24.04 hostname
```

Expected: the second `srun`'s container start phase is subseconds (the issue today shows ~38 s). After both runs:

```bash
ssh spark-f2ff sudo zfs list -r "$(ssh spark-f2ff zfs list -H -o name '${ENROOT_DATA_PATH}')/.templates"
```

Expected: **one** template under `.templates/` for `ubuntu:24.04`, not two (the failure mode from issue #13).

- [ ] **Step 7: Eviction recovery**

```bash
sudo zfs destroy -r "$(zfs list -H -o name ${ENROOT_DATA_PATH})/.templates/$(zfs list -H -d 1 -o name $(zfs list -H -o name ${ENROOT_DATA_PATH})/.templates | tail -1 | awk -F/ '{print $NF}')"
enroot create -n u2 /tmp/u.sqsh
enroot remove -f u2
```

Expected: `enroot create` re-pulls from the registry, succeeds, container works.

- [ ] **Step 8: Format opt-out**

```bash
rm -f /tmp/u.sqsh
enroot import --format=squashfs docker://ubuntu:24.04 -o /tmp/u.sqsh
ls -la /tmp/u.sqsh
file /tmp/u.sqsh
unsquashfs -s /tmp/u.sqsh > /dev/null && echo OK_REAL_SQSH || echo BUG
```

Expected: file is ~30+ MiB; `file(1)` reports `Squashfs filesystem`; `OK_REAL_SQSH`.

- [ ] **Step 9: Wrong-backend error**

On a node with `ENROOT_STORAGE_BACKEND=dir`, copy a pointer file there and:

```bash
enroot create -n u3 /tmp/pointer.sqsh
```

Expected: clean error message naming `ENROOT_STORAGE_BACKEND=zfs is required to use it`.

- [ ] **Step 10: Backwards compat**

Verify a legacy real `.sqsh` (built with `--format=squashfs`) still works on a ZFS-backend node:

```bash
enroot create -n u4 /path/to/legacy/real.sqsh
enroot remove -f u4
```

Expected: succeeds via the existing `runtime::_create_zfs` path (sqsh-sha keyed). No change vs. v4.1.2.zfs.3.

- [ ] **Step 11: Record results**

Capture the wall-clock numbers for Tasks 4 and 6 in the eventual PR description (this is the issue's acceptance criterion: second `srun` create-step subseconds).

---

## Task 12: Open the PR

**Files:** N/A (git/gh operation only)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feature/zfs-pointer-import
```

- [ ] **Step 2: Open the PR against `zenroot/main`**

```bash
gh pr create --base zenroot/main --head feature/zfs-pointer-import \
  --title "ZFS: pointer-format import for stable template-cache hits (closes #13)" \
  --body "$(cat <<'EOF'
## Summary
- New default on the ZFS backend: `enroot import docker://<ref>` writes a 1-KiB pointer file (magic line `enroot-zfs-image:v1`) instead of a real squashfs. Skips `mksquashfs` entirely.
- `enroot create` magic-byte-sniffs the pointer, looks up the template by `image-config-sha256` (the existing layer-keyed cache key), and clones — `O(zfs clone)`.
- Repeat imports of the same image (the pyxis workflow) hit the cache; the second `enroot create` is subseconds.
- Opt out via `--format=squashfs` (CLI) or `ENROOT_ZFS_IMPORT_FORMAT=squashfs` (env/config).
- `dir` backend untouched. pyxis SPANK plugin needs no changes.

Design spec: `docs/superpowers/specs/2026-04-29-zfs-pointer-import-design.md`.

## Test plan
- [ ] Pointer import: `head -1 /tmp/u.sqsh` is `enroot-zfs-image:v1`; one new template under `${pool}/.templates/`.
- [ ] Pointer create hit: subseconds; container dataset is a clone.
- [ ] Repeat import: no new template; cache hit.
- [ ] Pyxis end-to-end: `srun --container-image=docker://ubuntu:24.04 …` twice; second invocation's create-step subseconds; one template per image, not two (issue #13's failure mode).
- [ ] Eviction recovery: destroy template, `enroot create` re-pulls and succeeds.
- [ ] `--format=squashfs` opt-out: real squashfs, no template populated by import.
- [ ] Wrong-backend error: pointer on dir-backend node → clean error.
- [ ] Backwards compat: legacy real `.sqsh` still works on ZFS backend (sqsh-sha-keyed path unchanged).

Closes #13.
EOF
)"
```

Expected: PR URL printed.

---

## Self-Review (run after writing the plan, before execution)

1. **Spec coverage.** Walk every section of the spec and confirm a task implements it.
   - Spec §3 (Approach): Tasks 1, 4, 5 (the install half + import + create orchestrators).
   - Spec §4 (Pointer file format): Task 3.
   - Spec §5.1 (`storage_zfs.sh` new functions): Tasks 1–5.
   - Spec §5.2 (`runtime.sh` hooks): Tasks 6, 7.
   - Spec §5.3 (`docker.sh` refactor): **Resolved differently** — `docker::_prepare_layers` is already factored, so no `docker::pull_layers_only` is needed. Spec §11 first open question is therefore N/A; this is noted in the plan headers (no docker.sh changes).
   - Spec §5.4 (`--format` CLI flag): Task 8.
   - Spec §6 (Data flow): Verified by Tasks 11.3, 11.4, 11.7.
   - Spec §7 (Configuration): Tasks 8, 9.
   - Spec §8 (Trust): write_pointer/read_pointer regex validation in Task 3; cross-validation in Task 5 (config-sha mismatch error).
   - Spec §9 (Testing): Task 11.
   - Spec §10 (Out of scope): respected.
   - Spec §11 second open question (layer-cache eviction): not special-cased; recovery does a full re-pull as designed.
   - Spec §11 third open question (split install+clone): resolved by Task 1 in favor of (a) — the cleaner split.
   - Spec §12 (Compatibility): Tasks 9 (docs), 10 (changelog).

2. **Placeholder scan.** No "TBD", "TODO", "implement later". Each step has either a complete code block or an exact command + expected output.

3. **Type/identifier consistency.** Function names verified across tasks: `zfs::_install_template_from_layers` (Task 1) is called by `zfs::_pull_and_install_template` (Task 5) and `zfs::import_docker_pointer` (Task 4). `zfs::is_pointer`, `zfs::write_pointer`, `zfs::read_pointer`, `zfs::pointer_format_active` defined in Task 3, used in Tasks 4, 5, 6, 7. The `image-config-sha256` field name is identical in spec §4 and Tasks 3, 5. The `ENROOT_ZFS_IMPORT_FORMAT` env var name is identical in Tasks 3, 7, 8, 9.
