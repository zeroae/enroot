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

# Computes the sha256 of a squashfs image file. Used as the template cache key.
zfs::image_sha256() {
    local -r image="$1"
    sha256sum "${image}" | awk '{print $1}'
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

    # Fast path: template already exists with @pristine.
    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        zfs::touch_template "${template}"
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

    zfs clone "${template}@${zfs_pristine_snap}" "${target}"
}

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
        zfs::touch_template "${template}"
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
        zfs::touch_template "${template}"
    else
        # Lost the race or stale .tmp — wait for @pristine.
        while ! zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; do
            sleep 1
            ((i++ < 600)) || common::err "Timed out waiting for Docker template: ${template}"
        done
    fi

    zfs::clone_container "${template}" "${name}"
}
