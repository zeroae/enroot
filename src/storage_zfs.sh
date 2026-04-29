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
