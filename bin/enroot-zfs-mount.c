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
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

#include "common.h"

#ifndef SYSCONFDIR
# define SYSCONFDIR "/usr/local/etc"
#endif
#define CONF_PATH SYSCONFDIR "/enroot/enroot.conf"

/*
 * Walks /proc/self/mounts looking for a "zfs" mount whose mountpoint covers
 * `data_path` (i.e., is data_path itself or a path-component ancestor of it).
 * Returns the longest-matching dataset name (malloc'd), or NULL if no zfs
 * mount covers data_path.
 */
static char *
resolve_parent_dataset(const char *data_path)
{
        FILE *f;
        char *line = NULL, *best_src = NULL;
        size_t len = 0, best_mp_len = 0, dp_len;
        ssize_t n;

        f = fopen("/proc/self/mounts", "r");
        if (f == NULL)
                err(EXIT_FAILURE, "cannot read /proc/self/mounts");

        dp_len = strlen(data_path);

        while ((n = getline(&line, &len, f)) != -1) {
                char src[PATH_MAX], mp[PATH_MAX], type[64];
                size_t mp_len;

                if (sscanf(line, "%4095s %4095s %63s", src, mp, type) != 3)
                        continue;
                if (strcmp(type, "zfs") != 0)
                        continue;

                mp_len = strlen(mp);
                /* mp must be data_path itself or a strict ancestor path. */
                if (mp_len > dp_len)
                        continue;
                if (strncmp(mp, data_path, mp_len) != 0)
                        continue;
                /* Disallow false prefix matches (e.g., "/foo" vs "/foobar"); the
                 * char in data_path right after mp must be '/' or end-of-string,
                 * unless mp is "/" itself. */
                if (mp_len > 1 && mp_len < dp_len && data_path[mp_len] != '/')
                        continue;

                if (mp_len > best_mp_len) {
                        free(best_src);
                        best_src = strdup(src);
                        if (best_src == NULL)
                                err(EXIT_FAILURE, "strdup");
                        best_mp_len = mp_len;
                }
        }
        free(line);
        fclose(f);
        return (best_src);
}


/*
 * Returns the ZFS `mountpoint` property of `dataset` (malloc'd absolute path),
 * or NULL on error / non-path values (e.g. "none", "legacy", "-"). Exec's
 * `zfs get -H -o value mountpoint DATASET` via popen.
 */
static char *
get_mountpoint(const char *dataset)
{
        char cmd[PATH_MAX + 64];
        FILE *p;
        char buf[PATH_MAX];
        char *result = NULL;

        /* dataset is single-quote-wrapped in the shell. ZFS dataset names
         * cannot contain single quotes (per the ZFS naming rules — only
         * alphanumerics, period, underscore, dash, colon, and slash), so
         * shell-injection via the dataset arg is not possible here. The
         * dataset has already been prefix-validated by path_under(). */
        int n = snprintf(cmd, sizeof(cmd),
                         "zfs get -H -o value mountpoint '%s' 2>/dev/null", dataset);
        if (n < 0 || n >= (int)sizeof(cmd))
                return (NULL);

        p = popen(cmd, "r");
        if (p == NULL)
                return (NULL);

        if (fgets(buf, sizeof(buf), p) != NULL) {
                size_t l = strlen(buf);
                if (l > 0 && buf[l - 1] == '\n')
                        buf[l - 1] = '\0';
                if (buf[0] == '/') {
                        result = strdup(buf);
                        if (result == NULL) {
                                SAVE_ERRNO(pclose(p));
                                err(EXIT_FAILURE, "strdup");
                        }
                }
        }
        pclose(p);
        return (result);
}

/* Returns true iff path is exactly prefix or under prefix/. */
static bool
path_under(const char *path, const char *prefix)
{
        size_t pl = strlen(prefix);

        if (strncmp(path, prefix, pl) != 0)
                return (false);
        return (path[pl] == '\0' || path[pl] == '/');
}

static struct capabilities_v3 caps;

/*
 * Reads ENROOT_DATA_PATH from the system enroot.conf. Returns a malloc'd
 * string the caller must free, or NULL if the key is absent. Errors out if
 * the conf file itself can't be opened.
 *
 * Format mirrors the bash side's IFS=$' \t=' read: lines are `KEY VALUE`
 * with whitespace or `=` as separator. Comments start with `#`.
 */
static char *
read_data_path(void)
{
        FILE *f;
        char *line = NULL;
        size_t len = 0;
        ssize_t n;
        char *result = NULL;

        f = fopen(CONF_PATH, "r");
        if (f == NULL)
                err(EXIT_FAILURE, "cannot read %s", CONF_PATH);

        while ((n = getline(&line, &len, f)) != -1) {
                char *p, *key;

                if (n > 0 && line[n - 1] == '\n')
                        line[n - 1] = '\0';

                p = line;
                while (*p == ' ' || *p == '\t')
                        p++;
                if (*p == '\0' || *p == '#')
                        continue;

                key = p;
                while (*p && *p != ' ' && *p != '\t' && *p != '=')
                        p++;
                if (*p == '\0')
                        continue;
                *p++ = '\0';
                while (*p == ' ' || *p == '\t' || *p == '=')
                        p++;

                if (!strcmp(key, "ENROOT_DATA_PATH")) {
                        result = strdup(p);
                        if (result == NULL)
                                err(EXIT_FAILURE, "strdup");
                        break;
                }
        }
        free(line);
        fclose(f);
        return (result);
}

/*
 * Walks /proc/self/mounts looking for a "zfs" mount whose SOURCE is
 * `dataset` (not whose mountpoint matches a path). Returns the current
 * mountpoint path (malloc'd), or NULL if the dataset isn't mounted anywhere
 * we can see.
 */
static char *
find_current_mountpoint(const char *dataset)
{
        FILE *f;
        char *line = NULL, *result = NULL;
        size_t len = 0;
        ssize_t n;

        f = fopen("/proc/self/mounts", "r");
        if (f == NULL)
                err(EXIT_FAILURE, "cannot read /proc/self/mounts");

        while ((n = getline(&line, &len, f)) != -1) {
                char src[PATH_MAX], mp[PATH_MAX], type[64];

                (void)n;

                if (sscanf(line, "%4095s %4095s %63s", src, mp, type) != 3)
                        continue;
                if (strcmp(type, "zfs") != 0)
                        continue;
                if (strcmp(src, dataset) == 0) {
                        result = strdup(mp);
                        if (result == NULL) {
                                free(line);
                                fclose(f);
                                err(EXIT_FAILURE, "strdup");
                        }
                        break;
                }
        }
        free(line);
        fclose(f);
        return (result);
}

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

static int
do_umount(const char *target, int flags)
{
        int rv;

        CAP_SET(&caps, effective, CAP_SYS_ADMIN);
        if (capset(&caps.hdr, caps.data) < 0)
                return (-1);

        rv = umount2(target, flags);

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

        char *data_path = read_data_path();
        if (data_path == NULL)
                errx(EXIT_FAILURE, "ENROOT_DATA_PATH is not set in %s", CONF_PATH);

        char *parent_ds = resolve_parent_dataset(data_path);
        if (parent_ds == NULL)
                errx(EXIT_FAILURE, "no ZFS dataset is mounted at or above %s", data_path);

        if (!path_under(dataset, parent_ds))
                errx(EXIT_FAILURE, "dataset %s is not under %s", dataset, parent_ds);

        if (do_unmount) {
                char *cur = find_current_mountpoint(dataset);
                if (cur == NULL) {
                        free(parent_ds);
                        free(data_path);
                        return (EXIT_SUCCESS);  /* not mounted; idempotent no-op */
                }
                if (!path_under(cur, data_path))
                        errx(EXIT_FAILURE, "current mountpoint %s is not under %s",
                             cur, data_path);
                if (do_umount(cur, 0) < 0)
                        err(EXIT_FAILURE, "umount %s", cur);
                free(cur);
                free(parent_ds);
                free(data_path);
                return (EXIT_SUCCESS);
        }

        char *mp = get_mountpoint(dataset);
        if (mp == NULL)
                errx(EXIT_FAILURE, "could not get mountpoint of %s (is it set to a path?)", dataset);
        if (!path_under(mp, data_path))
                errx(EXIT_FAILURE, "mountpoint %s is not under %s", mp, data_path);

        /* If the dataset is already mounted, succeed silently iff at the
         * expected mountpoint; error otherwise (defends against double-mounts
         * and surprises if a sibling mount table got reshuffled). */
        char *cur = find_current_mountpoint(dataset);
        if (cur != NULL) {
                if (strcmp(cur, mp) == 0) {
                        free(cur);
                        free(mp);
                        free(parent_ds);
                        free(data_path);
                        return (EXIT_SUCCESS);
                }
                errx(EXIT_FAILURE, "dataset %s is already mounted at %s", dataset, cur);
        }

        /* mkdir runs as the calling uid (DAC_OVERRIDE is in permitted but not
         * effective; we don't raise it). If the dir already exists this is a
         * no-op. If the calling user can't create it, that's the right
         * outcome — they don't have access to the parent. */
        if (mkdir(mp, 0755) < 0 && errno != EEXIST)
                err(EXIT_FAILURE, "mkdir %s", mp);

        if (do_mount(dataset, mp, "zfs", 0, NULL) < 0)
                err(EXIT_FAILURE, "mount %s on %s", dataset, mp);

        free(mp);
        free(parent_ds);
        free(data_path);
        return (EXIT_SUCCESS);
}
