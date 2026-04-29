/*
 * Copyright (c) 2018-2026, NVIDIA CORPORATION. All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#define _GNU_SOURCE
#include <err.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

#include "common.h"

static struct capabilities_v3 caps;

static void
init_capabilities(void)
{
        CAP_INIT_V3(&caps);

        if (capget(&caps.hdr, caps.data) < 0)
                err(EXIT_FAILURE, "failed to get capabilities");

        CAP_FOREACH(&caps, n) {
                if (n == CAP_DAC_READ_SEARCH || n == CAP_DAC_OVERRIDE)
                        continue;
                CAP_CLR(&caps, permitted, n);
                CAP_CLR(&caps, effective, n);
                CAP_CLR(&caps, inheritable, n);
        }
        CAP_SET(&caps, permitted, CAP_SYS_ADMIN);

        if (capset(&caps.hdr, caps.data) < 0)
                err(EXIT_FAILURE, "failed to set capabilities");
}

static int
do_mount(const char *source, const char *target, const char *fstype,
         unsigned long flags, const void *data)
{
        int rv;

        CAP_SET(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);

        rv = mount(source, target, fstype, flags, data);

        CAP_CLR(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);
        return (rv);
}

static void NORETURN
usage(const char *progname, int status)
{
        FILE *out = (status == EXIT_SUCCESS) ? stdout : stderr;
        fprintf(out, "Usage: %s [--unmount] DATASET\n", progname);
        fprintf(out, "\n");
        fprintf(out, "  Mount a ZFS DATASET at its declared mountpoint property.\n");
        fprintf(out, "  With --unmount, unmount the dataset's current mountpoint.\n");
        fprintf(out, "\n");
        fprintf(out, "  Refuses to operate on datasets outside the parent of\n");
        fprintf(out, "  ENROOT_DATA_PATH (read from /etc/enroot/enroot.conf), or\n");
        fprintf(out, "  whose mountpoint is not under ENROOT_DATA_PATH.\n");
        exit(status);
}

int
main(int argc, char *argv[])
{
        bool do_unmount = false;
        const char *dataset = NULL;

        if (argc == 2 && !strcmp(argv[1], "--help"))
                usage(argv[0], EXIT_SUCCESS);

        if (argc == 2) {
                dataset = argv[1];
        } else if (argc == 3 && !strcmp(argv[1], "--unmount")) {
                do_unmount = true;
                dataset = argv[2];
        } else {
                usage(argv[0], EXIT_FAILURE);
        }

        init_capabilities();

        /* TODO Task 2-4: validate the dataset before doing privileged work */

        if (do_unmount) {
                /* TODO Task 5 */
                errx(EXIT_FAILURE, "unmount not implemented yet");
        }

        if (do_mount(dataset, "/tmp/zfs-mount-skeleton-stub", "zfs", 0, NULL) < 0)
                err(EXIT_FAILURE, "mount failed");

        return (EXIT_SUCCESS);
}
