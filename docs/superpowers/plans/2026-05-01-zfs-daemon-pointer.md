# ZFS pointer-format for `dockerd://` / `podman://` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the zfs.4 pointer cache so `enroot import dockerd://<image>` and `enroot import podman://<image>` get the same cache-hit behavior as `docker://`. Cache key is the daemon-reported image ID. Pointer format gains an optional (omittable) `manifest-digest` field.

**Architecture:** Two new install / import primitives in `src/storage_zfs.sh` (`_install_template_from_dir`, `import_daemon_pointer`, `_extract_and_install_from_daemon`), refactor of `create_from_pointer`'s eviction-recovery to dispatch on URI scheme, a relaxed pointer URI regex, an optional `manifest-digest` schema, and a parallel branch in `runtime::import`'s dispatcher.

**Tech Stack:** Bash, OpenZFS, the existing `enroot-zfs-mount` helper, the daemon side already used by `docker::daemon::import`.

**Spec:** [docs/superpowers/specs/2026-05-01-zfs-daemon-pointer-design.md](../specs/2026-05-01-zfs-daemon-pointer-design.md).

**Branch:** `feature/zfs-daemon-pointer` (already created, spec committed there).

---

## Task 1: Relax pointer schema (optional `manifest-digest`, widened URI regex)

**Why:** Daemon-local images don't have a registry manifest digest, and the URI regex needs to accept `dockerd://` and `podman://`.

**Files:** `src/storage_zfs.sh` — `zfs::write_pointer`, `zfs::read_pointer`, `zfs::set_template_metadata`.

- [ ] **Step 1: Relax `write_pointer` — accept empty `manifest_digest`, omit the line when empty**

Find in `zfs::write_pointer` (around line 195-215):

```bash
    [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || common::err "zfs::write_pointer: invalid manifest-digest: ${manifest_digest}"
```

Replace with:

```bash
    if [ -n "${manifest_digest}" ]; then
        [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
          || common::err "zfs::write_pointer: invalid manifest-digest: ${manifest_digest}"
    fi
```

Then find the line that emits the manifest-digest field:

```bash
        printf "manifest-digest=%s\n" "${manifest_digest}"
```

Wrap in a conditional:

```bash
        [ -n "${manifest_digest}" ] && printf "manifest-digest=%s\n" "${manifest_digest}"
```

- [ ] **Step 2: Relax URI regex in `write_pointer`**

Find:

```bash
    [[ "${uri}" =~ ^docker://[A-Za-z0-9._:/@+-]+$ ]] \
      || common::err "zfs::write_pointer: invalid uri: ${uri}"
```

Replace with:

```bash
    [[ "${uri}" =~ ^(docker|dockerd|podman)://[A-Za-z0-9._:/@+-]+$ ]] \
      || common::err "zfs::write_pointer: invalid uri: ${uri}"
```

- [ ] **Step 3: Same relaxation in `read_pointer`**

Find the validation block in `zfs::read_pointer`:

```bash
    [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || common::err "Pointer ${path} missing/invalid manifest-digest"
```

Replace with:

```bash
    if [ -n "${manifest_digest}" ]; then
        [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
          || common::err "Pointer ${path} invalid manifest-digest"
    fi
```

And the URI regex:

```bash
    [[ "${uri}" =~ ^docker://[A-Za-z0-9._:/@+-]+$ ]] \
      || common::err "Pointer ${path} missing/invalid uri"
```

→

```bash
    [[ "${uri}" =~ ^(docker|dockerd|podman)://[A-Za-z0-9._:/@+-]+$ ]] \
      || common::err "Pointer ${path} missing/invalid uri"
```

- [ ] **Step 4: `set_template_metadata` skips empty manifest-digest**

Find:

```bash
zfs::set_template_metadata() {
    local -r template="$1" uri="$2" manifest_digest="$3" arch="$4"
    zfs set "enroot:uri=${uri}" "${template}" 2> /dev/null || :
    zfs set "enroot:manifest-digest=${manifest_digest}" "${template}" 2> /dev/null || :
    zfs set "enroot:arch=${arch}" "${template}" 2> /dev/null || :
}
```

Replace the manifest-digest set with a conditional:

```bash
zfs::set_template_metadata() {
    local -r template="$1" uri="$2" manifest_digest="$3" arch="$4"
    zfs set "enroot:uri=${uri}" "${template}" 2> /dev/null || :
    if [ -n "${manifest_digest}" ]; then
        zfs set "enroot:manifest-digest=${manifest_digest}" "${template}" 2> /dev/null || :
    fi
    zfs set "enroot:arch=${arch}" "${template}" 2> /dev/null || :
}
```

- [ ] **Step 5: Syntax-check + smoke**

```bash
bash -n src/storage_zfs.sh
```

Quick round-trip test that v4 pointers (with manifest-digest) and new pointers (without) both work:

```bash
bash -c "set -euo pipefail
export ENROOT_LIBRARY_PATH=src
source src/common.sh
source src/storage_zfs.sh
out=\$(mktemp)
echo '=== with manifest-digest (v4 form) ==='
zfs::write_pointer \"\${out}\" 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' 'sha256:abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' arm64 'docker://x/y:z'
zfs::is_pointer \"\${out}\" && echo IS_POINTER
zfs::read_pointer \"\${out}\"
echo '=== without manifest-digest (new form) ==='
zfs::write_pointer \"\${out}\" 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' '' arm64 'dockerd://ubuntu:24.04'
zfs::is_pointer \"\${out}\" && echo IS_POINTER
cat \"\${out}\"
zfs::read_pointer \"\${out}\"
rm -f \"\${out}\"
"
```

Expected: round-trip OK both forms; the without form has no `manifest-digest=` line in the file; both pass `is_pointer`.

- [ ] **Step 6: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: relax pointer schema for daemon URIs

Manifest-digest becomes optional in the pointer format (write_pointer
omits the line when empty; read_pointer tolerates absence). The URI
regex widens to ^(docker|dockerd|podman)://… so the cache can carry
daemon-local image references that don't have a registry manifest digest.

v1 magic line is unchanged; existing v4 pointers (always with
manifest-digest) still parse correctly under the relaxed reader.

set_template_metadata skips the enroot:manifest-digest property when
the value is empty so daemon templates don't carry a confusing empty
property."
```

---

## Task 2: Add `zfs::_install_template_from_dir`

**Why:** Daemon imports give us a flat rootfs (no overlayfs layers); we need a template-install primitive that fills the `.tmp` dataset from a single source directory.

**Files:** `src/storage_zfs.sh` — append after the existing `zfs::_install_template_from_layers` (around line 800-870 area).

- [ ] **Step 1: Locate `zfs::_install_template_from_layers`**

```bash
grep -n "^zfs::_install_template_from_layers\|^zfs::docker_install_from_layers" src/storage_zfs.sh
```

- [ ] **Step 2: Append the new helper directly after `zfs::docker_install_from_layers`**

(Match the indentation, comment style, and atomicity tail of `_install_template_from_layers`. Tar-pipe is the simplest cross-FS copy that preserves perms/xattrs.)

```bash

# Materializes a flat rootfs directory tree into a ZFS template (cached
# by cache_key). Counterpart of _install_template_from_layers for callers
# that already have a single rootfs/ tree (e.g. docker::daemon::import,
# which uses `${engine} export | tar -x` to produce a flat tree).
#
# Inputs:
#   $1 cache_key   - sha256 of the image config (the daemon image ID)
#   $2 source_dir  - directory containing the rootfs to install
#   $3 unpriv      - "y" or "" — whether to enter a new user namespace
#
# Outputs: prints the template dataset path to stdout (no trailing newline).
#
# Atomicity: races on the same cache_key are resolved via a per-key .tmp
# dataset lock; losers wait for @pristine. Same shape as
# _install_template_from_layers.
zfs::_install_template_from_dir() {
    local -r cache_key="$1" source_dir="$2" unpriv="$3"
    local store template tmp snap mountpoint i=0
    store=$(zfs::store_dataset)
    template="${store}/${zfs_template_subdir}/${cache_key}"
    tmp="${template}.tmp"
    snap="${template}@${zfs_pristine_snap}"

    zfs::sweep_templates

    zfs create -u "${store}/${zfs_template_subdir}" 2> /dev/null || :
    enroot-zfs-mount "${store}/${zfs_template_subdir}" 2> /dev/null || :

    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        common::log INFO "Reusing cached template ${cache_key:0:12}"
        zfs::touch_template "${template}"
    elif zfs create -u "${tmp}" 2> /dev/null; then
        if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
            zfs destroy "${tmp}" 2> /dev/null || :
            common::err "failed to mount daemon template"
        fi
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        local copy_cmd
        copy_cmd="tar --numeric-owner -C '${source_dir}/' --mode=u-s,g-s -cpf - . | tar --numeric-owner -C '${mountpoint}/' -xpf -"
        if ! enroot-nsenter ${unpriv:+--user} --mount --remap-root bash -c "${copy_cmd}"; then
            common::log WARN "Daemon template copy failed; evicting all warm templates and retrying"
            ENROOT_TEMPLATE_WARM_SECONDS=0 zfs::sweep_templates
            enroot-nsenter ${unpriv:+--user} --mount --remap-root bash -c "${copy_cmd}" \
              || { zfs destroy -r "${tmp}" 2> /dev/null || :; \
                   common::err "Failed to copy daemon rootfs into ZFS template even after evicting warm templates"; }
        fi
        enroot-zfs-mount --unmount "${tmp}" 2> /dev/null || :
        zfs rename "${tmp}" "${template}"
        enroot-zfs-mount "${template}" 2> /dev/null || :
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}" 2> /dev/null || :
        zfs set "enroot:imported=$(date -u +%FT%TZ)" "${template}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${template}" 2> /dev/null || :
        zfs::touch_template "${template}"
    else
        # Lost the race or stale .tmp — wait for @pristine.
        while ! zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; do
            sleep 1
            ((i++ < 600)) || common::err "Timed out waiting for daemon template: ${template}"
        done
    fi

    printf "%s" "${template}"
}
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

- [ ] **Step 4: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add _install_template_from_dir

Counterpart of _install_template_from_layers for callers that already
have a flat rootfs (e.g. dockerd:// / podman:// imports, where
\`\${engine} export | tar -x\` produces a single tree, not layered
overlayfs directories). Same atomicity / race / snapshot / readonly /
unmount-after-install / enroot:imported tail."
```

---

## Task 3: Add `zfs::_extract_and_install_from_daemon`

**Why:** Shared helper for the import path AND the eviction-recovery path. Modeled on `zfs::_pull_and_install_template`.

**Files:** `src/storage_zfs.sh` — append near `zfs::_pull_and_install_template`.

- [ ] **Step 1: Locate `zfs::_pull_and_install_template`**

```bash
grep -n "^zfs::_pull_and_install_template" src/storage_zfs.sh
```

- [ ] **Step 2: Append the daemon variant after it**

```bash

# Internal helper used by both the daemon-import flow and the
# create_from_pointer recovery path for dockerd://podman:// URIs. Runs
# \`\${engine} create + inspect + export | tar -x\`, populates the template
# from the resulting flat rootfs, prints the resolved image-config-sha256
# (the daemon image ID) so the caller can validate it. Does NOT write a
# pointer file.
#
# Inputs:
#   $1 uri    - dockerd://<image> or podman://<image>
#   $2 arch   - already debarch-normalized (callers must convert with
#               common::debarch first, or pass the value already stored
#               in a pointer file).
#
# Subshell function for cwd / EXIT trap scoping (matches
# _pull_and_install_template).
zfs::_extract_and_install_from_daemon() (
    local -r uri="$1" arch="$2"
    local image= tmpdir= engine= cache_key= unpriv=
    local image_id=

    set -euo pipefail

    case "${uri}" in
        dockerd://*) engine="docker" ;;
        podman://*)  engine="podman" ;;
        *)           common::err "_extract_and_install_from_daemon: not a daemon URI: ${uri}" ;;
    esac

    common::checkcmd jq "${engine}" tar

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

    trap 'common::rmall "${tmpdir}" 2> /dev/null; "${engine}" rm -f -v "${tmpdir##*/}" > /dev/null 2>&1' EXIT
    tmpdir=$(common::mktmpdir enroot)
    common::chdir "${tmpdir}"

    common::log INFO "Extracting image content from ${engine} daemon..." NL
    "${engine}" create --name "${PWD##*/}" "${image}" >&2
    mkdir rootfs
    "${engine}" export "${PWD##*/}" \
      | tar -C rootfs --warning=no-timestamp --anchored --exclude='dev/*' --exclude='.dockerenv' -px
    common::fixperms rootfs
    "${engine}" inspect "${image}" | common::jq '.[] | with_entries(.key|=ascii_downcase)' > config
    docker::configure rootfs config "${arch}"

    if [ "${EUID}" -ne 0 ]; then
        unpriv=y
    fi

    zfs::_install_template_from_dir "${cache_key}" "${PWD}/rootfs" "${unpriv}" > /dev/null

    printf "%s" "${cache_key}"
)
```

- [ ] **Step 3: Syntax-check + dependency sanity**

```bash
bash -n src/storage_zfs.sh
grep -n "_install_template_from_dir\|_extract_and_install_from_daemon" src/storage_zfs.sh
```

Both should appear (definition + nothing else yet).

- [ ] **Step 4: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add _extract_and_install_from_daemon

Daemon-side analog of zfs::_pull_and_install_template. Runs
\`\${engine} create / inspect / export | tar -x\`, derives the cache key
from the daemon's image ID, and populates the template via
_install_template_from_dir. Subshell function with set -euo pipefail
for cwd / EXIT scoping, matches the docker:// puller's pattern.

No callers yet — wired in by Tasks 4 and 5."
```

---

## Task 4: Add `zfs::import_daemon_pointer` (top-level entry)

**Why:** Counterpart of `zfs::import_docker_pointer` for daemon URIs. Runs the daemon-extract + template-install + pointer-write pipeline.

**Files:** `src/storage_zfs.sh` — append after `zfs::import_docker_pointer`.

- [ ] **Step 1: Locate `zfs::import_docker_pointer`**

```bash
grep -n "^zfs::import_docker_pointer" src/storage_zfs.sh
```

- [ ] **Step 2: Append the daemon-side import**

```bash

# Import flow for dockerd://*  / podman://* URIs when the ZFS backend is
# active and the pointer format is selected. Modeled on
# import_docker_pointer but uses the daemon-extract path
# (_extract_and_install_from_daemon). manifest-digest is empty —
# daemon-local images don't have a registry manifest digest.
#
# Inputs:
#   $1 uri          - dockerd://<image>  or  podman://<image>
#   $2 output_path  - where to write the pointer (caller pre-validated)
#   $3 arch         - raw uname -m form; normalized internally via
#                     common::debarch.
zfs::import_daemon_pointer() (
    local -r uri="$1" output_path="$2"
    local arch="$3"
    local cache_key=

    set -euo pipefail

    if [ -n "${arch}" ]; then
        arch=$(common::debarch "${arch}")
    fi

    cache_key=$(zfs::_extract_and_install_from_daemon "${uri}" "${arch}")

    local store
    store=$(zfs::store_dataset)
    zfs::set_template_metadata "${store}/${zfs_template_subdir}/${cache_key}" \
        "${uri}" "" "${arch}"

    zfs::write_pointer "${output_path}" "${cache_key}" "" "${arch}" "${uri}"
)
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

- [ ] **Step 4: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add zfs::import_daemon_pointer

Top-level orchestrator for dockerd://podman:// pointer imports. Calls
_extract_and_install_from_daemon to populate the template, stamps the
docker provenance (uri + arch; no manifest-digest for daemon images),
writes the pointer file. Empty manifest-digest is handled by the
schema-relax in Task 1 — no \`manifest-digest=\` line is emitted, and
the read_pointer side tolerates the absence."
```

---

## Task 5: Refactor `zfs::create_from_pointer` recovery to dispatch on URI scheme

**Why:** The existing recovery only knows how to re-pull `docker://` URIs. With daemon URIs in the mix, recovery branches.

**Files:** `src/storage_zfs.sh` — `zfs::create_from_pointer`.

- [ ] **Step 1: Locate the eviction-recovery block**

```bash
grep -n "fresh_config_sha=\|_pull_and_install_template" src/storage_zfs.sh
```

- [ ] **Step 2: Replace the single call with a scheme dispatch**

Find:

```bash
    fresh_config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}")
```

Replace with:

```bash
    case "${uri}" in
        docker://*)
            fresh_config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}") ;;
        dockerd://*|podman://*)
            fresh_config_sha=$(zfs::_extract_and_install_from_daemon "${uri}" "${arch}") ;;
        *)
            common::err "Pointer ${pointer_path} has unsupported URI scheme: ${uri}" ;;
    esac
```

- [ ] **Step 3: Syntax-check + verify dispatch**

```bash
bash -n src/storage_zfs.sh
grep -n "_pull_and_install_template\|_extract_and_install_from_daemon\|fresh_config_sha=" src/storage_zfs.sh
```

Expected: each helper called exactly once from inside the case.

- [ ] **Step 4: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: dispatch eviction-recovery on URI scheme

create_from_pointer now branches on docker:// vs dockerd://podman:// in
its eviction-recovery path. Daemon URIs use the new
_extract_and_install_from_daemon helper; docker:// URIs continue to use
_pull_and_install_template. An unrecognized scheme errors with a clear
message rather than silently picking the docker:// path."
```

---

## Task 6: Wire `runtime::import` daemon-side branch

**Why:** Make the dispatcher route `dockerd://*|podman://*` through `zfs::import_daemon_pointer` when the ZFS pointer format is active.

**Files:** `src/runtime.sh` — `runtime::import`.

- [ ] **Step 1: Read the current dispatcher**

```bash
grep -n "^runtime::import\|dockerd://\|podman://" src/runtime.sh
```

- [ ] **Step 2: Add the daemon branch**

In `runtime::import`, find:

```bash
    dockerd://* | podman://*)
        docker::daemon::import "${uri}" "${filename}" "${arch}" ;;
```

Replace with:

```bash
    dockerd://* | podman://*)
        if zfs::pointer_format_active; then
            # ZFS pointer-format daemon import: write a small magic-prefixed
            # pointer file alongside populating the template cache.
            # Filename defaulting mirrors docker::daemon::import — daemon URIs
            # have a `<scheme>://<image-ref>` shape; default filename slugs
            # the image ref into a .sqsh path.
            if [ -z "${filename}" ]; then
                local _image=
                local -r _reg_image="[[:alnum:]/._:-]+"
                if [[ "${uri}" =~ ^[[:alpha:]]+://(${_reg_image})$ ]]; then
                    _image="${BASH_REMATCH[1]}"
                else
                    common::err "Invalid image reference: ${uri}"
                fi
                filename="${_image//[:\/]/+}.sqsh"
            fi
            filename=$(common::realpath "${filename}")
            if [ -e "${filename}" ]; then
                common::err "File already exists: ${filename}"
            fi
            zfs::import_daemon_pointer "${uri}" "${filename}" "${arch}"
        else
            docker::daemon::import "${uri}" "${filename}" "${arch}"
        fi ;;
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/runtime.sh
```

- [ ] **Step 4: Commit**

```bash
git add src/runtime.sh
git commit -s -m "runtime: pointer-format dispatch for daemon URIs

Adds the dockerd://podman:// branch parallel to the existing docker://
branch in runtime::import. When ENROOT_STORAGE_BACKEND=zfs and
ENROOT_ZFS_IMPORT_FORMAT is unset or 'pointer', daemon imports now call
zfs::import_daemon_pointer (writes a pointer + populates the template
cache, skips mksquashfs) instead of docker::daemon::import.

Filename defaulting mirrors docker::daemon::import's '<image>.sqsh'
slug. ENROOT_ZFS_IMPORT_FORMAT=squashfs preserves the legacy daemon
import behavior."
```

---

## Task 7: Doc note in `doc/zfs.md`

**Why:** Operators reading the pointer-format section should know the cache covers daemon URIs too.

**Files:** `doc/zfs.md` — the existing `## Pointer-format import (default on ZFS backend)` section.

- [ ] **Step 1: Find the right place**

```bash
grep -n "^## Pointer-format import\|^### Opting out" doc/zfs.md
```

- [ ] **Step 2: Append a new subsection just before `### Opting out`**

```markdown
### Daemon URIs (`dockerd://`, `podman://`)

`enroot import dockerd://<image>` and `enroot import podman://<image>` participate in the same pointer cache. The cache key is the daemon-reported image ID (`${engine} inspect --format='{{.Id}}'`), which matches the `image-config-sha256` of a `docker://`-pulled equivalent for registry-pulled images — so a daemon import of `ubuntu:24.04` shares the cache with a registry import of the same reference for free.

Daemon-local images don't have a registry manifest digest, so the pointer file's `manifest-digest=` line is omitted. The `enroot:manifest-digest` user property is also unset on the corresponding template. All other fields (`enroot:uri`, `enroot:arch`, `enroot:imported`) are populated normally; the inspection one-liner above shows daemon-sourced templates with `enroot:uri=dockerd://...`.
```

- [ ] **Step 3: Verify code fences balance**

```bash
grep -c '^```' doc/zfs.md
```

- [ ] **Step 4: Commit**

```bash
git add doc/zfs.md
git commit -s -m "doc: zfs.md note on daemon URI cache parity

Documents that dockerd://podman:// imports use the same pointer cache
as docker://, with the daemon image ID as the cache key. Notes the
omitted manifest-digest field for daemon-local images."
```

---

## Task 8: Smoke-test (manual, on a ZFS-backed node with docker or podman)

The project has no automated tests. Verification is by hand.

- [ ] **Step 1: Build .deb on dev box**

```bash
make clean
rm -f ../enroot_*.orig.tar.* ../enroot-hardened_*.orig.tar.*
CPPFLAGS="-DALLOW_SPECULATION -DINHERIT_FDS" make deb
```

- [ ] **Step 2: Install on a test node with docker daemon available**

Per CLAUDE.md "Smoke-test cluster" section.

- [ ] **Step 3: Pre-pull a known image into the daemon (if not already)**

```bash
sudo docker pull ubuntu:24.04
```

- [ ] **Step 4: Daemon pointer import**

```bash
rm -f /tmp/d.sqsh
enroot import -o /tmp/d.sqsh dockerd://ubuntu:24.04
ls -la /tmp/d.sqsh
head -1 /tmp/d.sqsh
cat /tmp/d.sqsh
```

Expected: file < 1 KiB; first line `enroot-zfs-image:v1`; body has `image-config-sha256=`, `arch=`, `uri=dockerd://ubuntu:24.04`, `imported=`; NO `manifest-digest=` line.

- [ ] **Step 5: Cache-hit create**

```bash
enroot remove -f c1 2>/dev/null
time enroot create -n c1 /tmp/d.sqsh
enroot start c1 cat /etc/os-release | head -1
enroot remove -f c1
```

Expected: subseconds; container starts.

- [ ] **Step 6: Repeat-import idempotence**

```bash
sudo zfs list -H -d 1 -o name ${POOL}/.templates | wc -l
rm -f /tmp/d.sqsh
enroot import -o /tmp/d.sqsh dockerd://ubuntu:24.04
sudo zfs list -H -d 1 -o name ${POOL}/.templates | wc -l
```

Expected: template count unchanged; "Reusing cached template" log.

- [ ] **Step 7: Eviction recovery**

```bash
sudo zfs destroy -r ${POOL}/.templates/<image-id-sha>
enroot remove -f c2 2>/dev/null
enroot create -n c2 /tmp/d.sqsh
enroot remove -f c2
```

Expected: re-extracts from the daemon and clones successfully.

- [ ] **Step 8: docker:// path still works (no regression)**

```bash
rm -f /tmp/u.sqsh
enroot import -o /tmp/u.sqsh docker://ubuntu:24.04
head -1 /tmp/u.sqsh
grep '^manifest-digest=' /tmp/u.sqsh   # should appear (registry-sourced)
```

- [ ] **Step 9: --format=squashfs opt-out for daemon URI**

```bash
rm -f /tmp/d-real.sqsh
enroot import --format=squashfs -o /tmp/d-real.sqsh dockerd://ubuntu:24.04
file /tmp/d-real.sqsh    # → Squashfs filesystem
rm -f /tmp/d-real.sqsh
```

---

## Self-Review Checklist

1. **Spec coverage:** §3.1 (cache key) → Task 3. §3.2 (`_install_template_from_dir`) → Task 2. §3.3 (`import_daemon_pointer`) → Task 4. §3.4 (optional manifest-digest, URI regex relax) → Task 1. §3.5 (recovery dispatch) → Task 5. §3.6 (`runtime::import` wiring) → Task 6. §3.7 (doc) → Task 7.
2. **Identifier consistency:** `zfs::_install_template_from_dir`, `zfs::_extract_and_install_from_daemon`, `zfs::import_daemon_pointer` named identically across plan, spec, and tasks. URI regex uses `^(docker|dockerd|podman)://` consistently in all three places (Task 1 steps 2, 3, and the conceptual schema).
3. **No placeholders:** every code block is complete; no "TBD" / "TODO".
