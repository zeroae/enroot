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
