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
readonly zfs_ephemeral_subdir=".ephemeral"
readonly zfs_layers_subdir=".layers"
readonly zfs_layer_done_snap="done"

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

# Updates the enroot:last_used user property on a template dataset to now.
# Used by the eviction sweep to distinguish warm (recently-used) templates
# from cold (idle past ENROOT_TEMPLATE_WARM_SECONDS) ones. Best-effort: a
# read-only template (set by ensure_template) is touched via -o so the
# readonly property doesn't block the metadata update.
zfs::touch_template() {
    local -r template="$1"
    zfs set "enroot:last_used=$(date +%s)" "${template}" 2> /dev/null || :
}

# Stamps a template dataset with docker provenance properties so the
# dataset is self-describing even after its (transient) pointer file is
# gone. Always called from a context where the inputs have already been
# regex-validated (write_pointer / read_pointer in zfs.4 — the callers
# pass values that survived those regex gates), so we don't re-validate
# here. Best-effort: any property set that fails (e.g. delegation
# missing on an upgraded cluster) is silently ignored — the template
# still functions; only the operator-visible metadata is degraded.
zfs::set_template_metadata() {
    local -r template="$1" uri="$2" manifest_digest="$3" arch="$4"
    zfs set "enroot:uri=${uri}" "${template}" 2> /dev/null || :
    if [ -n "${manifest_digest}" ]; then
        zfs set "enroot:manifest-digest=${manifest_digest}" "${template}" 2> /dev/null || :
    fi
    zfs set "enroot:arch=${arch}" "${template}" 2> /dev/null || :
}

# Returns 0 iff a fully-materialized template (with @pristine snapshot) exists
# for the given cache_key. Cheap predicate; does not run the eviction sweep.
zfs::template_exists() {
    local -r cache_key="$1"
    local store
    store=$(zfs::store_dataset)
    zfs list -H -t snapshot "${store}/${zfs_template_subdir}/${cache_key}@${zfs_pristine_snap}" > /dev/null 2>&1
}

# Prints "<dataset>\t<last_used_epoch>" for each evictable template, sorted
# oldest-first. A template is evictable iff it has @pristine and that snapshot
# has no clones referencing it. Datasets without a last_used property report
# "-"; the sweep treats these as cold (effectively age = +infinity).
zfs::eviction_candidates() {
    local -r store=$(zfs::store_dataset)
    local -r templates_dataset="${store}/${zfs_template_subdir}"
    local ds ts clones

    # Bail if the templates parent doesn't exist yet.
    zfs list -H "${templates_dataset}" > /dev/null 2>&1 || return 0

    # Direct children only (-d 1, exclude self via $1 != ds-parent).
    while IFS=$'\t' read -r ds ts; do
        [ "${ds}" = "${templates_dataset}" ] && continue
        clones=$(zfs get -H -o value clones "${ds}@${zfs_pristine_snap}" 2> /dev/null) || continue
        if [ -z "${clones}" ] || [ "${clones}" = "-" ]; then
            printf "%s\t%s\n" "${ds}" "${ts:--}"
        fi
    done < <(zfs list -H -r -d 1 -t filesystem -o name,enroot:last_used "${templates_dataset}") \
      | sort -t $'\t' -k2,2n
}

# Returns 0 if the templates dataset has a quota set and current usage is at
# or above ENROOT_TEMPLATE_PRESSURE_THRESHOLD percent. Returns 1 otherwise
# (no quota = no pressure check; under threshold = no pressure).
zfs::under_pressure() {
    local -r store=$(zfs::store_dataset)
    local -r templates_dataset="${store}/${zfs_template_subdir}"
    local quota used pct

    zfs list -H "${templates_dataset}" > /dev/null 2>&1 || return 1

    quota=$(zfs get -H -p -o value quota "${templates_dataset}")
    [ "${quota}" = "0" ] || [ "${quota}" = "-" ] && return 1

    used=$(zfs get -H -p -o value used "${templates_dataset}")
    pct=$(( used * 100 / quota ))

    [ "${pct}" -ge "${ENROOT_TEMPLATE_PRESSURE_THRESHOLD-80}" ]
}

# Sweeps evictable templates. Always reaps cold ones (last_used older than
# ENROOT_TEMPLATE_WARM_SECONDS); also reaps warm ones LRU when under pressure,
# stopping once back under threshold. With ENROOT_TEMPLATE_WARM_SECONDS=0 and
# no quota, this collapses to "reap any template with no clones" (refcount-only
# behavior, equivalent to Plan A's destroy_container).
zfs::sweep_templates() {
    local now warm_secs pressure ds ts age is_warm
    now=$(date +%s)
    warm_secs="${ENROOT_TEMPLATE_WARM_SECONDS-604800}"
    zfs::under_pressure && pressure=y || pressure=

    zfs::eviction_candidates | while IFS=$'\t' read -r ds ts; do
        if [ -z "${ts}" ] || [ "${ts}" = "-" ]; then
            age=$((warm_secs + 1))   # missing timestamp = treat as cold
        else
            age=$(( now - ts ))
        fi
        if [ "${age}" -lt "${warm_secs}" ] && [ -z "${pressure}" ]; then
            continue                  # warm and no pressure: keep
        fi
        common::log INFO "Evicting template ${ds##*/} (age ${age}s)"
        zfs destroy "${ds}@${zfs_pristine_snap}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${ds}" 2> /dev/null || :
        zfs destroy "${ds}" 2> /dev/null || :
        if [ -n "${pressure}" ]; then
            zfs::under_pressure || break
        fi
    done
}

# Computes the sha256 of a squashfs image file. Used as the template cache key.
zfs::image_sha256() {
    local -r image="$1"
    sha256sum "${image}" | awk '{print $1}'
}

# Pointer file format: a small plain-text artifact written by
# enroot import docker://... when the ZFS backend is active. It carries
# the stable image-config-sha256 (the cache key used by
# zfs::_install_template_from_layers) plus enough metadata to recover from
# template eviction by re-pulling from the registry. Filename stays .sqsh
# so pyxis (which feeds the path back to enroot create unchanged) is
# unaware of the format change. enroot create magic-byte-sniffs the first
# 19 bytes (`enroot-zfs-image:v1`) and dispatches to the pointer path.
readonly zfs_pointer_magic="enroot-zfs-image:v1"

# Returns 0 iff the ZFS backend is active AND ENROOT_ZFS_LAYER_CHAIN=y.
# Callers gate the per-layer-clone-chain template-fill path on this. The
# default-off behavior (unset / "" / anything but "y") preserves Plan F's
# single-merge path byte-for-byte.
zfs::layer_chain_active() {
    zfs::enabled || return 1
    [ "${ENROOT_ZFS_LAYER_CHAIN-}" = "y" ]
}

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
# squashfs blobs, ZFS send streams, and short/empty files. Uses cmp
# directly rather than `head=$(dd ...)`-and-compare so binary inputs
# don't trigger bash's "ignored null byte in input" warning on the
# command substitution.
zfs::is_pointer() {
    local -r path="$1"
    [ -f "${path}" ] || return 1
    printf '%s' "${zfs_pointer_magic}" | cmp -s -n 19 - "${path}"
}

# Atomically writes a pointer file at $1 with the given fields. Uses
# tmp + rename so partial writes never leave a half-formed pointer behind.
# All inputs are validated; refuses to write a pointer with a malformed
# config_sha or manifest_digest.
zfs::write_pointer() {
    local -r output="$1" config_sha="$2" manifest_digest="$3" arch="$4" uri="$5"
    local tmp imported

    # Strict regexes here are not just sanity checks — read_pointer prints
    # KEY=VALUE pairs that callers consume via eval. Any value that flows
    # into eval must be free of shell metacharacters ($, `, ;, (, ), |, &,
    # space, newline, etc.). The character classes below all forbid them.
    [[ "${config_sha}" =~ ^[0-9a-f]{64}$ ]] \
      || common::err "zfs::write_pointer: invalid image-config-sha256: ${config_sha}"
    if [ -n "${manifest_digest}" ]; then
        [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
          || common::err "zfs::write_pointer: invalid manifest-digest: ${manifest_digest}"
    fi
    [[ "${arch}" =~ ^[a-z0-9_-]+$ ]] \
      || common::err "zfs::write_pointer: invalid arch: ${arch}"
    [[ "${uri}" =~ ^(docker|dockerd|podman)://[A-Za-z0-9._:/@+-]+$ ]] \
      || common::err "zfs::write_pointer: invalid uri: ${uri}"

    imported=$(date -u +%FT%TZ)
    tmp="${output}.tmp.$$"
    {
        printf "%s\n" "${zfs_pointer_magic}"
        printf "image-config-sha256=%s\n" "${config_sha}"
        # manifest-digest is optional — daemon-local images (dockerd:// /
        # podman://) don't have a registry manifest digest. Omit the line
        # entirely when empty so the field's absence is unambiguous.
        [ -n "${manifest_digest}" ] && printf "manifest-digest=%s\n" "${manifest_digest}"
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

    while IFS='=' read -r key value; do
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

    # All five fields are validated against strict regexes before output —
    # the caller will eval the printed KEY=VALUE pairs, so values must be
    # free of shell metacharacters. The classes below all forbid them.
    [[ "${config_sha}" =~ ^[0-9a-f]{64}$ ]] \
      || common::err "Pointer ${path} missing/invalid image-config-sha256"
    # manifest-digest is optional — daemon-local imports (dockerd:// /
    # podman://) omit it because the daemon doesn't carry a registry
    # manifest digest. Validate the format only when the field is present.
    if [ -n "${manifest_digest}" ]; then
        [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
          || common::err "Pointer ${path} invalid manifest-digest"
    fi
    [[ "${arch}" =~ ^[a-z0-9_-]+$ ]] \
      || common::err "Pointer ${path} missing/invalid arch"
    [[ "${uri}" =~ ^(docker|dockerd|podman)://[A-Za-z0-9._:/@+-]+$ ]] \
      || common::err "Pointer ${path} missing/invalid uri"
    [[ "${imported}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
      || common::err "Pointer ${path} missing/invalid imported timestamp"

    # Emit shell-friendly names (underscores, not hyphens) so the caller
    # can `eval` the output directly. The on-disk pointer format keeps
    # the docker-conventional hyphenated names; this is just the eval
    # interface.
    printf "image_config_sha256=%s\n" "${config_sha}"
    printf "manifest_digest=%s\n"     "${manifest_digest}"
    printf "arch=%s\n"                "${arch}"
    printf "uri=%s\n"                 "${uri}"
    printf "imported=%s\n"            "${imported}"
}

# Ensures a template dataset exists for the given image hash, extracting if needed.
# Prints the template's full dataset name (e.g. tank/enroot/.templates/<sha>).
# Atomic across concurrent callers via a per-hash .tmp dataset.
zfs::ensure_template() {
    local -r image="$1" sha="$2"
    local -r store=$(zfs::store_dataset)
    local -r template="${store}/${zfs_template_subdir}/${sha}"
    local -r tmp="${template}.tmp"
    local -r snap="${template}@${zfs_pristine_snap}"
    local mountpoint
    local i timeout=600

    zfs::sweep_templates

    # Fast path: template already exists with @pristine.
    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
    fi

    # Ensure the templates parent exists. Use -u so Linux does not auto-mount it
    # (which would require CAP_SYS_ADMIN); mount it explicitly via the helper.
    local -r templates_ds="${store}/${zfs_template_subdir}"
    zfs create -u "${templates_ds}" 2> /dev/null || :
    enroot-zfs-mount "${templates_ds}" 2> /dev/null || :

    # Try to create the .tmp dataset atomically. Whoever wins is the extractor.
    # -u: skip auto-mount (Linux requires CAP_SYS_ADMIN for mount(2)); we call
    # enroot-zfs-mount explicitly below. No -p needed — parent was ensured above.
    if zfs create -u "${tmp}" 2> /dev/null; then
        # We won — mount it via the cap-elevated helper so unprivileged callers
        # can write into it. Linux mount(2) needs CAP_SYS_ADMIN regardless of
        # 'zfs allow' delegation; enroot-zfs-mount (in the +caps package)
        # carries cap_sys_admin and validates the dataset is under
        # ENROOT_DATA_PATH before mounting.
        if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
            zfs destroy "${tmp}" 2> /dev/null || :
            common::err "failed to mount template; install enroot+caps to enable unprivileged mount"
        fi
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        common::log INFO "Extracting squashfs filesystem into ZFS template..." NL
        [ $(ulimit -n) -gt $((2**26)) ] && ulimit -n $((2**26))
        if ! unsquashfs ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
                        -user-xattrs -f -d "${mountpoint}" "${image}" >&2; then
            common::log WARN "Extraction failed; evicting all warm templates and retrying"
            ENROOT_TEMPLATE_WARM_SECONDS=0 zfs::sweep_templates
            unsquashfs ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
                       -user-xattrs -f -d "${mountpoint}" "${image}" >&2 \
              || { zfs destroy -r "${tmp}" 2> /dev/null || :; \
                   common::err "Extraction failed even after evicting warm templates"; }
        fi
        common::fixperms "${mountpoint}"
        enroot-zfs-mount --unmount "${tmp}" 2> /dev/null || :
        zfs rename "${tmp}" "${template}"
        enroot-zfs-mount "${template}" 2> /dev/null || :
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}" 2> /dev/null || :
        zfs set "enroot:imported=$(date -u +%FT%TZ)" "${template}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${template}" 2> /dev/null || :
        zfs::touch_template "${template}"
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

    # canmount=noauto skips the auto-mount on create (works on OpenZFS 2.0+).
    # `zfs clone -u` would do the same but is only in 2.3+; `-o canmount=noauto`
    # is the portable equivalent. The helper's mount(2) call below is unaffected
    # by canmount (it bypasses ZFS's own mount machinery).
    zfs clone -o canmount=noauto "${template}@${zfs_pristine_snap}" "${target}"
    if ! enroot-zfs-mount "${target}" 2> /dev/null; then
        zfs destroy "${target}" 2> /dev/null || :
        common::err "failed to mount cloned container ${name}"
    fi
}

# Destroys a user container. The clone's origin template is left in place;
# its lifecycle is owned by zfs::sweep_templates (warm/cold/pressure-driven
# eviction on next create), so a remove + re-create cycle within
# ENROOT_TEMPLATE_WARM_SECONDS reuses the cached template instead of
# re-extracting.
zfs::destroy_container() {
    local -r name="$1"
    local -r store=$(zfs::store_dataset)
    local -r target="${store}/${name}"

    if ! zfs list -H "${target}" > /dev/null 2>&1; then
        common::err "No such container: ${name}"
    fi
    enroot-zfs-mount --unmount "${target}" 2> /dev/null || :
    zfs destroy "${target}"
}

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
    zfs create -u "${store}/${zfs_ephemeral_subdir}" 2> /dev/null || :
    enroot-zfs-mount "${store}/${zfs_ephemeral_subdir}" 2> /dev/null || :
    # canmount=noauto skips the auto-mount on clone (portable across OpenZFS
    # 2.0+; `zfs clone -u` would do the same but is only in 2.3+).
    zfs clone -o canmount=noauto "${template}@${zfs_pristine_snap}" "${clone}"
    zfs set readonly=off "${clone}"
    if ! enroot-zfs-mount "${clone}" 2> /dev/null; then
        zfs destroy "${clone}" 2> /dev/null || :
        common::err "failed to mount ephemeral clone"
    fi

    mountpoint=$(zfs get -H -o value mountpoint "${clone}")
    printf "%s\t%s" "${clone}" "${mountpoint}"
}

# Destroys an ephemeral clone. Best-effort; intended for cleanup hooks.
zfs::ephemeral_destroy() {
    local -r clone="$1"
    [ -z "${clone}" ] && return
    enroot-zfs-mount --unmount "${clone}" 2> /dev/null || :
    zfs destroy "${clone}" 2> /dev/null || :
}

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

# Parses a zfs:// URI and prints two lines: the host and the container name
# (NAME may contain extra path components which are reassembled into the
# container name). Matches the docker::_parse_uri output convention so callers
# can use the same `common::read -r` pattern.
zfs::parse_uri() {
    local -r uri="$1"
    if [[ ! "${uri}" =~ ^zfs://([^/]+)/(.+)$ ]]; then
        common::err "Invalid zfs:// URI: ${uri}"
    fi
    printf "%s\n%s\n" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Sends a clone's @pristine snapshot (or a fresh snapshot if the container is
# not a clone) to stdout. Used by --zfs-send.
zfs::send_clone_stdout() {
    local -r name="$1"
    local -r store=$(zfs::store_dataset)
    local -r target="${store}/${name}"
    local origin

    if ! zfs list -H "${target}" > /dev/null 2>&1; then
        common::err "No such container: ${name}"
    fi

    origin=$(zfs get -H -o value origin "${target}")
    if [ -z "${origin}" ] || [ "${origin}" = "-" ]; then
        local snap="${target}@enroot-export-$$"
        zfs snapshot "${snap}"
        trap "zfs destroy '${snap}' 2> /dev/null || :" RETURN
        zfs send "${snap}"
    else
        zfs send "${origin}"
    fi
}

# Receives a zfs send stream from stdin into the template cache, then clones
# the resulting template into a named user container. Used by --zfs-recv.
# The cache key is the sha256 of the (buffered) stream bytes — same scheme as
# zfs::create_from_stream uses for .zfs files.
zfs::recv_to_template_stdin() {
    local -r name="$1"
    local buf sha template

    buf=$(mktemp -p "${ENROOT_TEMP_PATH:-/tmp}" enroot-recv.XXXXXX)
    trap "rm -f '${buf}' 2> /dev/null || :" RETURN
    cat > "${buf}"
    sha=$(zfs::image_sha256 "${buf}")
    template=$(zfs::ensure_template_from_stream "${buf}" "${sha}")
    zfs::clone_container "${template}" "${name}"
}

# Imports a container from a remote enroot host over SSH and writes a file.
# Output format is inferred from the filename extension: ".sqsh" produces a
# squashfs (requires local ZFS to receive into a temp dataset, mksquashfs out,
# then destroy the temp); anything else produces a raw zfs send stream
# (".zfs" by convention; no local ZFS receive required).
zfs::import_uri() {
    local -r uri="$1"
    local filename="$2"
    local host remote_name

    common::checkcmd ssh
    zfs::parse_uri "${uri}" \
      | { common::read -r host; common::read -r remote_name; }

    if [ -z "${filename}" ]; then
        filename="${remote_name##*/}.zfs"
    fi
    filename=$(common::realpath "${filename}")
    if [ -e "${filename}" ]; then
        if [ -z "${ENROOT_FORCE_OVERRIDE-}" ]; then
            common::err "File already exists: ${filename}"
        else
            rm -f "${filename}"
        fi
    fi

    case "${filename}" in
        *.sqsh)
            zfs::checkenv
            common::checkcmd mksquashfs
            local -r store=$(zfs::store_dataset)
            local -r tmp_ds="${store}/${zfs_template_subdir}/import-$$.tmp"
            local mountpoint
            zfs create -u "${store}/${zfs_template_subdir}" 2> /dev/null || :
            enroot-zfs-mount "${store}/${zfs_template_subdir}" 2> /dev/null || :
            common::log INFO "Pulling ${remote_name} from ${host} (sqsh)" NL
            if ! ssh "${host}" enroot export --zfs-send "${remote_name}" \
                  | zfs receive -F "${tmp_ds}"; then
                zfs destroy -r "${tmp_ds}" 2> /dev/null || :
                common::err "Receive from ${uri} failed"
            fi
            mountpoint=$(zfs get -H -o value mountpoint "${tmp_ds}")
            common::log INFO "Creating squashfs filesystem..." NL
            mksquashfs "${mountpoint}" "${filename}" -all-root ${TTY_OFF+-no-progress} \
              -processors "${ENROOT_MAX_PROCESSORS}" ${ENROOT_SQUASH_OPTIONS} >&2 \
              || { zfs destroy -r "${tmp_ds}" 2> /dev/null || :; \
                   common::err "mksquashfs failed"; }
            zfs destroy -r "${tmp_ds}"
            ;;
        *)
            common::log INFO "Pulling ${remote_name} from ${host} (zfs send stream)" NL
            ssh "${host}" enroot export --zfs-send "${remote_name}" > "${filename}" \
              || { rm -f "${filename}"; common::err "ssh transport failed for ${uri}"; }
            ;;
    esac
}

# Pulls a container from a remote enroot host over SSH. URI is zfs://host/NAME;
# the SSH peer must be running enroot with the ZFS backend. Local NAME
# defaults to the URI's basename if not given.
zfs::pull_via_ssh() {
    local -r uri="$1"
    local name="$2"
    local host remote_name

    common::checkcmd ssh
    zfs::parse_uri "${uri}" \
      | { common::read -r host; common::read -r remote_name; }

    [ -z "${name}" ] && name="${remote_name##*/}"

    common::log INFO "Pulling ${remote_name} from ${host}" NL
    ssh "${host}" enroot export --zfs-send "${remote_name}" \
      | zfs::recv_to_template_stdin "${name}"
}

# Pushes a local container to a remote enroot host over SSH. URI may be
# zfs://host (push under the same NAME) or zfs://host/REMOTE_NAME (rename on
# the remote side).
zfs::push_via_ssh() {
    local -r name="$1" uri="$2"
    local host remote_name

    common::checkcmd ssh
    if [[ "${uri}" =~ ^zfs://([^/]+)/?(.*)$ ]]; then
        host="${BASH_REMATCH[1]}"
        remote_name="${BASH_REMATCH[2]:-${name}}"
    else
        common::err "Invalid zfs:// URI: ${uri}"
    fi

    common::log INFO "Pushing ${name} to ${host} as ${remote_name}" NL
    zfs::send_clone_stdout "${name}" \
      | ssh "${host}" enroot import --zfs-recv -n "${remote_name}"
}

# Materializes a ZFS stream file into a template (cached by file sha) and
# clones it as the user's named container. Counterpart of zfs::ensure_template
# + zfs::clone_container for the .sqsh path; this is called from runtime::create
# when the input image has a .zfs extension.
zfs::create_from_stream() {
    local -r image="$1" name="$2"
    local sha template

    zfs::checkenv
    sha=$(zfs::image_sha256 "${image}")
    template=$(zfs::ensure_template_from_stream "${image}" "${sha}")
    zfs::clone_container "${template}" "${name}"
}

# Exports a clone's @pristine snapshot as a zfs send stream file. Owns
# filename defaulting and the file-already-exists guard so runtime::export's
# ZFS branch is a single dispatch call.
zfs::export_to_file() {
    local -r name="$1"
    local filename="$2"

    if [ -z "${filename}" ]; then
        filename="${name}.zfs"
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
    zfs::send_stream "${name}" "${filename}"
}

# Materializes a template from a zfs send stream file. The cache key is the
# sha256 of the stream file (same scheme as the .sqsh path). Atomic via a
# .tmp dataset; integrates with the same eviction sweep as ensure_template.
zfs::ensure_template_from_stream() {
    local -r stream="$1" sha="$2"
    local -r store=$(zfs::store_dataset)
    local -r template="${store}/${zfs_template_subdir}/${sha}"
    local -r tmp="${template}.tmp"
    local -r snap="${template}@${zfs_pristine_snap}"
    local i timeout=600

    zfs::sweep_templates

    # Fast path: already cached.
    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
    fi

    # Ensure the templates parent exists before receive (zfs receive does not
    # auto-create parents). Use -u to skip auto-mount; mount explicitly.
    zfs create -u "${store}/${zfs_template_subdir}" 2> /dev/null || :
    enroot-zfs-mount "${store}/${zfs_template_subdir}" 2> /dev/null || :

    if zfs receive -u -F "${tmp}" < "${stream}" 2> /dev/null; then
        if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
            zfs destroy -r "${tmp}" 2> /dev/null || :
            common::err "failed to mount received template"
        fi
        # The received dataset brings its own snapshot. Rename the dataset to
        # the final template name; if the recv'd snapshot wasn't already named
        # @pristine, alias it.
        enroot-zfs-mount --unmount "${tmp}" 2> /dev/null || :
        zfs rename "${tmp}" "${template}"
        enroot-zfs-mount "${template}" 2> /dev/null || :
        if ! zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
            local recvd_snap
            recvd_snap=$(zfs list -H -t snapshot -o name -r -d 1 "${template}" | head -1)
            [ -n "${recvd_snap}" ] && zfs rename "${recvd_snap}" "${snap}"
        fi
        zfs set readonly=on "${template}" 2> /dev/null || :
        zfs set "enroot:imported=$(date -u +%FT%TZ)" "${template}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${template}" 2> /dev/null || :
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
    fi

    # Receive failed. Clean our orphan .tmp (if any) and wait for another
    # writer's @pristine.
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

# Sends a clone's @pristine snapshot (or a fresh snapshot if the container is
# not a clone) to stdout. Used by --format=zfs export.
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
        if ! zfs send "${snap}" > "${filename}"; then
            zfs destroy "${snap}" 2> /dev/null || :
            common::err "Failed to send stream for ${name}"
        fi
        zfs destroy "${snap}" 2> /dev/null || :
    else
        zfs send "${origin}" > "${filename}" \
          || common::err "Failed to send stream for ${name}"
    fi
}

# Generates the bash payload that applies one already-extracted layer
# directory (post enroot-aufs2ovlfs, so whiteouts are mknod 0:0 char
# devices and opaque dirs carry trusted.overlay.opaque=y) on top of an
# already-merged target directory. Designed to be passed to
# `enroot-nsenter --user --remap-root --mount bash -c`.
#
# Two placeholders @@LAYER@@ / @@TARGET@@ are sed-substituted at
# generation time; both paths come from ZFS dataset mountpoints whose
# names derive from regex-validated digests + ENROOT_DATA_PATH, so they
# can't contain shell metacharacters. The payload itself uses single
# quotes around the substituted paths and double quotes around the
# loop-local `${var}` interpolations so a path containing whitespace
# (rare but legal in mountpoints) does not break the apply.
zfs::_apply_layer_payload() {
    local -r layer_dir="$1" target_dir="$2"
    sed -e "s#@@LAYER@@#${layer_dir}#g" -e "s#@@TARGET@@#${target_dir}#g" <<'PAYLOAD'
set -euo pipefail
mount --make-rprivate /
cd '@@LAYER@@'

# Phase 1: opaque-dir clearing. trusted.overlay.opaque=y on a layer dir
# means "ignore everything from the parent in this dir"; we replicate
# that by clearing the corresponding target dir's children before
# layering this layer's contents on top.
getfattr -R -h --absolute-names -n trusted.overlay.opaque . 2>/dev/null \
  | awk -F': ' 'sub(/^# file: /, "")' \
  | while IFS= read -r d; do
        rel="${d#./}"
        find '@@TARGET@@/'"${rel}" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || :
    done

# Phase 2: whiteout deletion. Each char-device 0:0 in the layer encodes
# "this path is removed in this layer". Be defensive — only treat 0:0
# devices as whiteouts; any non-0:0 char dev (legitimate but unusual)
# is left for phase 3 to copy forward.
find . -type c | while IFS= read -r wh; do
    [ "$(stat -c '%t-%T' "${wh}" 2>/dev/null)" = "0-0" ] || continue
    rm -rf '@@TARGET@@/'"${wh#./}"
done

# Phase 3: tar-pipe non-whiteout contents into the target. xattrs
# (overlayfs opaque markers, capability bits, SELinux labels) and ACLs
# are preserved. Char devices are excluded — both the 0:0 whiteouts we
# already actioned in phase 2 and any other char devs (which would not
# be expected in Docker images post extraction).
find . -type c -printf '%P\n' > /tmp/.enroot-excludes.$$
tar -C . --exclude-from=/tmp/.enroot-excludes.$$ \
    --xattrs --xattrs-include='*' --acls -cpf - . \
  | tar -C '@@TARGET@@' --xattrs --xattrs-include='*' --acls -xpf -
rm -f /tmp/.enroot-excludes.$$
PAYLOAD
}

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
# Outputs: prints the template dataset path to stdout (no trailing newline).
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
        # `zfs set readonly=on` triggers an implicit remount that needs
        # CAP_SYS_ADMIN; for unprivileged callers the property is set but
        # the remount fails and zfs(8) exits non-zero. Suppress both the
        # warning and the non-zero exit — what we actually care about
        # (the property bit) is set regardless of the remount.
        zfs set readonly=on "${template}" 2> /dev/null || :
        zfs set "enroot:imported=$(date -u +%FT%TZ)" "${template}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${template}" 2> /dev/null || :
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

# Materializes a flat rootfs directory tree into a ZFS template (cached
# by cache_key). Counterpart of _install_template_from_layers for callers
# that already have a single rootfs/ tree (e.g. the dockerd:// / podman://
# import path, where `${engine} export | tar -x` produces a flat tree, not
# layered overlayfs directories).
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

# Builds one layer dataset on top of prev_layer (or as a base if prev_layer
# is empty). Idempotent: if <store>/.layers/<digest>@done already exists, no
# work is done. Race-safe via a per-digest .tmp dataset lock; losers wait
# for @done. ENOSPC during apply triggers a single warm-template-eviction
# retry, mirroring Plan B's pattern.
#
# Inputs:
#   $1 digest      - the layer's content digest (cache key under .layers/)
#   $2 prev_layer  - parent dataset name (empty for the base layer)
#   $3 layer_dir   - extracted-layer directory in cwd (1, 2, ..., N from
#                    docker::_prepare_layers' parallel extraction step)
#   $4 unpriv      - "y" or "" — passed through to enroot-nsenter
zfs::_build_layer() {
    local -r digest="$1" prev_layer="$2" layer_dir="$3" unpriv="$4"
    local store layer tmp snap mountpoint payload
    local create_ok= i=0

    store=$(zfs::store_dataset)
    layer="${store}/${zfs_layers_subdir}/${digest}"
    tmp="${layer}.tmp"
    snap="${layer}@${zfs_layer_done_snap}"

    # Cache hit: already built.
    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        return
    fi

    # Try to win the lock. Base layers create-from-scratch; non-base layers
    # clone the previous layer's @done. canmount=noauto avoids ZFS auto-mount
    # (which would need CAP_SYS_ADMIN) — we mount via enroot-zfs-mount below.
    if [ -z "${prev_layer}" ]; then
        zfs create -u "${tmp}" 2> /dev/null && create_ok=y
    else
        zfs clone -o canmount=noauto "${prev_layer}@${zfs_layer_done_snap}" "${tmp}" 2> /dev/null && create_ok=y
    fi

    if [ -z "${create_ok}" ]; then
        # Lost the race or stale .tmp. Wait briefly for another writer to
        # finalize @done; on timeout, surface for manual cleanup.
        while ! zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; do
            sleep 1
            ((i++ < 600)) || common::err "Timed out waiting for layer ${digest:0:12} (stale ${tmp}?)"
        done
        return
    fi

    # Clones inherit readonly=on from the parent's snapshot; we need to write
    # the layer's contents into the .tmp dataset before snapshotting, so flip
    # it back off here. This is unprivileged-safe: 'zfs allow' includes the
    # readonly property in the standard delegation set.
    zfs set readonly=off "${tmp}" 2> /dev/null || :
    if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
        zfs destroy "${tmp}" 2> /dev/null || :
        common::err "failed to mount layer ${digest:0:12}"
    fi
    mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
    common::log INFO "Building layer ${digest:0:12}..."

    payload=$(zfs::_apply_layer_payload "${PWD}/${layer_dir}" "${mountpoint}")
    if ! enroot-nsenter ${unpriv:+--user} --mount --remap-root bash -c "${payload}"; then
        common::log WARN "Layer apply failed; evicting all warm templates and retrying"
        ENROOT_TEMPLATE_WARM_SECONDS=0 zfs::sweep_templates
        enroot-nsenter ${unpriv:+--user} --mount --remap-root bash -c "${payload}" \
          || { zfs destroy -r "${tmp}" 2> /dev/null || :; \
               common::err "Failed to apply layer ${digest:0:12} even after evicting warm templates"; }
    fi

    enroot-zfs-mount --unmount "${tmp}" 2> /dev/null || :
    zfs rename "${tmp}" "${layer}"
    enroot-zfs-mount "${layer}" 2> /dev/null || :
    zfs snapshot "${snap}"
    zfs set readonly=on "${layer}" 2> /dev/null || :
    zfs set "enroot:layer-digest=${digest}" "${layer}" 2> /dev/null || :
    zfs set "enroot:imported=$(date -u +%FT%TZ)" "${layer}" 2> /dev/null || :
    enroot-zfs-mount --unmount "${layer}" 2> /dev/null || :
}

# Materializes the merged Docker rootfs into a ZFS template (cached by
# cache_key) by building a per-layer clone chain under <store>/.layers/.
# Drop-in replacement for _install_template_from_layers when chain mode
# (ENROOT_ZFS_LAYER_CHAIN=y) is active. Designed to be called from
# docker::load (or _pull_and_install_template) AFTER docker::_prepare_layers
# has populated the cwd with extracted, whiteout-converted layer
# directories 0/, 1/, ..., N/ and written the digest list to ./.layers.
#
# The leaf of the layer chain is cloned into <store>/.templates/<cache_key>
# with @pristine snapshot, so the resulting template is shape-compatible
# with Plan F templates: clone_container, the pointer-format flow, eviction
# recovery, and zfs:// transport all work unchanged.
#
# Inputs:
#   $1 cache_key   - sha256 of the image config blob
#   $2 layer_count - the N from _prepare_layers
#   $3 unpriv      - "y" or "" — passed through to enroot-nsenter
#   $4..$(3+N)     - layer digests in stack order, base first, top last
#
# Outputs: prints the template dataset path on stdout (no trailing newline).
#
# Atomicity: per-layer races resolved via <digest>.tmp dataset locks
# (see _build_layer); the final template is created via the same .tmp
# pattern as Plan F's _install_template_from_layers, so concurrent
# imports of the same image collapse onto one builder.
zfs::_install_layer_chain() {
    local -r cache_key="$1" layer_count="$2" unpriv="$3"
    shift 3
    local -a digests=("$@")
    local store template tmp snap prev_layer leaf_layer
    local i wait_i=0

    if [ "${#digests[@]}" -ne "${layer_count}" ]; then
        common::err "_install_layer_chain: digest count (${#digests[@]}) != layer_count (${layer_count})"
    fi

    store=$(zfs::store_dataset)
    template="${store}/${zfs_template_subdir}/${cache_key}"
    tmp="${template}.tmp"
    snap="${template}@${zfs_pristine_snap}"

    zfs::sweep_templates

    # Ensure parent containers exist without auto-mounting them (mount(2)
    # needs CAP_SYS_ADMIN; the helper below applies it via the +caps file
    # capability).
    zfs create -u "${store}/${zfs_template_subdir}" 2> /dev/null || :
    enroot-zfs-mount "${store}/${zfs_template_subdir}" 2> /dev/null || :
    zfs create -u "${store}/${zfs_layers_subdir}" 2> /dev/null || :
    enroot-zfs-mount "${store}/${zfs_layers_subdir}" 2> /dev/null || :

    # Fast path: template already cached — nothing to do.
    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        common::log INFO "Reusing cached template ${cache_key:0:12}"
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
    fi

    # Build the chain bottom-up. _build_layer is idempotent on cache hit,
    # so a partial earlier chain (e.g. base layers reused from another
    # image) costs only the missing top layers.
    prev_layer=""
    for ((i=0; i<layer_count; i++)); do
        zfs::_build_layer "${digests[i]}" "${prev_layer}" "$((i+1))" "${unpriv}"
        prev_layer="${store}/${zfs_layers_subdir}/${digests[i]}"
    done
    leaf_layer="${prev_layer}"

    # Final: clone the leaf as the user-visible template. canmount=noauto
    # so we control mount via the helper. Same .tmp-then-rename race
    # protection as Plan F's _install_template_from_layers.
    if zfs clone -o canmount=noauto "${leaf_layer}@${zfs_layer_done_snap}" "${tmp}" 2> /dev/null; then
        # The clone needs no contents work — it's already the merged
        # rootfs. Mount it just long enough to validate, then snapshot.
        if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
            zfs destroy "${tmp}" 2> /dev/null || :
            common::err "failed to mount template clone of layer leaf"
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
            ((wait_i++ < 600)) || common::err "Timed out waiting for chain template: ${template}"
        done
    fi

    printf "%s" "${template}"
}

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
#   $3 arch         - raw uname -m form (e.g. "aarch64"); normalized internally
#                     via common::debarch, same convention as docker::import /
#                     docker::load. Empty means "skip arch validation".
#
# Subshell function (parens) so cwd and EXIT trap stay scoped to this call —
# matches docker::import / docker::load.
zfs::import_docker_pointer() (
    local -r uri="$1" output_path="$2"
    local arch="$3"
    local config_sha= manifest_digest=

    set -euo pipefail

    # Fetch the manifest digest first (cheap HEAD on the manifest URL).
    # docker::digest takes raw arch and normalizes internally — pass it
    # the unmodified caller-supplied arch.
    manifest_digest=$(docker::digest "${uri}" "${arch}")
    [[ "${manifest_digest}" =~ ^sha256:[0-9a-f]{64}$ ]] \
      || common::err "registry returned invalid manifest digest: ${manifest_digest}"

    # Convert the architecture to the debian format for the internal
    # helpers. _pull_and_install_template expects already-normalized arch.
    if [ -n "${arch}" ]; then
        arch=$(common::debarch "${arch}")
    fi

    config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}")

    local store
    store=$(zfs::store_dataset)
    zfs::set_template_metadata "${store}/${zfs_template_subdir}/${config_sha}" \
        "${uri}" "${manifest_digest}" "${arch}"

    zfs::write_pointer "${output_path}" "${config_sha}" "${manifest_digest}" "${arch}" "${uri}"
)

# Import flow for dockerd:// / podman:// URIs when the ZFS backend is
# active and the pointer format is selected. Modeled on
# import_docker_pointer but uses the daemon-extract path
# (_extract_and_install_from_daemon). manifest-digest is empty —
# daemon-local images don't have a registry manifest digest, and the
# pointer schema (Task 1) makes it optional.
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
zfs::create_from_pointer() (
    local -r pointer_path="$1" name="$2"
    local fresh_config_sha
    local image_config_sha256= manifest_digest= arch= uri= imported=
    local store template

    set -euo pipefail

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
    # The pointer's `arch` is already debian-normalized (write_pointer
    # was given the normalized form), so pass it straight through to the
    # puller, which expects normalized.
    case "${uri}" in
        docker://*)
            fresh_config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}") ;;
        dockerd://*|podman://*)
            fresh_config_sha=$(zfs::_extract_and_install_from_daemon "${uri}" "${arch}") ;;
        *)
            common::err "Pointer ${pointer_path} has unsupported URI scheme: ${uri}" ;;
    esac
    if [ "${fresh_config_sha}" != "${image_config_sha256}" ]; then
        common::err "Pointer ${pointer_path} references image-config-sha256 ${image_config_sha256:0:12}, but ${uri} now resolves to ${fresh_config_sha:0:12}. Delete and re-import."
    fi

    store=$(zfs::store_dataset)
    template="${store}/${zfs_template_subdir}/${image_config_sha256}"
    zfs::set_template_metadata "${template}" "${uri}" "${manifest_digest}" "${arch}"
    zfs::clone_container "${template}" "${name}"
)

# Internal helper used by both the import flow's recovery path and (via
# zfs::import_docker_pointer) the main import flow. Pulls layers and
# installs the template; prints the resolved image-config-sha256 so the
# caller can validate it. Does NOT write a pointer file.
#
# Inputs:
#   $1 uri    - docker:// URI
#   $2 arch   - ALREADY debarch-normalized (callers must convert with
#               common::debarch first, or pass through the value already
#               stored in a pointer file).
#
# Subshell function for cwd / EXIT trap scoping (see import_docker_pointer
# for the same rationale).
zfs::_pull_and_install_template() (
    local -r uri="$1" arch="$2"
    local user= registry= image= tag= tmpdir= config= layer_count= unpriv=

    set -euo pipefail

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
)

# Internal helper used by both the daemon-import flow and the
# create_from_pointer recovery path for dockerd:// / podman:// URIs. Runs
# `${engine} create + inspect + export | tar -x`, populates the template
# from the resulting flat rootfs, prints the resolved
# image-config-sha256 (the daemon image ID) so the caller can validate
# it. Does NOT write a pointer file.
#
# Inputs:
#   $1 uri    - dockerd://<image>  or  podman://<image>
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
