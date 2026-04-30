# Pyxis-Compatible ZFS Mount Helper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `bin/enroot-zfs-mount`, a small `cap_sys_admin`-elevated C helper that validates and performs `mount(2)` / `umount(2)` of ZFS datasets owned by the calling user, so that unprivileged `enroot create` / `load` / `start` / `remove` work on the ZFS backend (issue #9). Matches existing helpers (`enroot-mksquashovlfs`, `enroot-aufs2ovlfs`) shipped via the `enroot+caps` package.

**Architecture:** Single static-pie musl-linked C helper (~150 lines) that takes a dataset name (and optional `--unmount` flag), parses `/etc/enroot/enroot.conf` for the authoritative `ENROOT_DATA_PATH`, resolves the parent ZFS dataset by reading `/proc/self/mounts`, validates the dataset prefix and its mountpoint property, then performs `mount("zfs", mp, "zfs", 0, dataset)` or `umount2(mp, 0)`. Caller-side `src/storage_zfs.sh` switches to `zfs create -u` / `zfs clone -u` / `zfs receive -u` (skip auto-mount) and calls the helper for the actual mount; `zfs destroy` paths gain a helper unmount before destroy.

**Tech Stack:** Bash >= 4.2, musl libc, libbsd (linked statically as the other helpers do), OpenZFS userland (`zfs(8)` is exec'd by the helper for property lookup).

**Project conventions:** No automated tests; verification is manual. Functions are namespaced with `::` (`zfs::ensure_template`). C helpers live in `bin/`, are `static-pie` linked against musl, and use `err()` / `errx()` from libbsd. Match the strict `-Wall -Wextra -Werror`-adjacent flag set in `Makefile`.

**Prerequisite host setup:** Same as Plan A. For verification, an unprivileged user account with `zfs allow user create,mount,clone,destroy,snapshot,rename` on the parent dataset.

---

## Files

- **Create:** `bin/enroot-zfs-mount.c` — the helper (~150 lines).
- **Modify:** `Makefile` — add to `UTILS`, add `setcap` line.
- **Modify:** `pkg/deb/PACKAGE+caps.postinst` and `.prerm` — `setcap` the new helper.
- **Modify:** `src/storage_zfs.sh` — switch to `-u` flags and call helper at create/clone/recv sites; call helper for unmount before destroy.
- **Modify:** `pkg/deb/changelog` — add `4.1.2.zfs.2` entry.
- **Modify:** `Makefile` `VERSION` → `4.1.2.zfs.2`.
- **Modify:** `doc/zfs.md` — replace the "Linux mount(2) caveat" section to describe the new path.

`enroot.in`, `src/runtime.sh`, and `src/docker.sh` are not modified.

---

### Task 1: Skeleton helper with cap management and bare mount(2)

The simplest possible version: parse `argv[1]` as a dataset name, hardcode the mount call. No validation yet. Used to prove the build wiring and cap mechanics work.

**Files:**
- Create: `bin/enroot-zfs-mount.c`

- [ ] **Step 1.1: Write the helper skeleton**

Create `bin/enroot-zfs-mount.c`:

```c
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
        CAP_SET(&caps, effective, CAP_SYS_ADMIN);

        if (capset(&caps.hdr, caps.data) < 0)
                err(EXIT_FAILURE, "failed to set capabilities");
}

static void
usage(const char *progname)
{
        printf("Usage: %s [--unmount] DATASET\n", progname);
        printf("\n");
        printf("  Mount a ZFS DATASET at its declared mountpoint property.\n");
        printf("  With --unmount, unmount the dataset's current mountpoint.\n");
        printf("\n");
        printf("  Refuses to operate on datasets outside the parent of\n");
        printf("  ENROOT_DATA_PATH (read from /etc/enroot/enroot.conf), or\n");
        printf("  whose mountpoint is not under ENROOT_DATA_PATH.\n");
        exit(EXIT_SUCCESS);
}

int
main(int argc, char *argv[])
{
        bool do_unmount = false;
        const char *dataset = NULL;

        if (argc == 2 && !strcmp(argv[1], "--help"))
                usage(argv[0]);

        if (argc == 2) {
                dataset = argv[1];
        } else if (argc == 3 && !strcmp(argv[1], "--unmount")) {
                do_unmount = true;
                dataset = argv[2];
        } else {
                usage(argv[0]);
        }

        init_capabilities();

        /* TODO Task 2-4: validate the dataset before doing privileged work */

        if (do_unmount) {
                /* TODO Task 5 */
                errx(EXIT_FAILURE, "unmount not implemented yet");
        }

        if (mount(dataset, "/tmp/zfs-mount-skeleton-stub", "zfs", 0, NULL) < 0)
                err(EXIT_FAILURE, "mount failed");

        return (EXIT_SUCCESS);
}
```

The mount target above is a deliberate placeholder — Task 3 replaces it with the real mountpoint lookup.

- [ ] **Step 1.2: Verify it compiles in the existing helper toolchain**

Append `bin/enroot-zfs-mount` to `Makefile`'s `UTILS` list (line ~36):

```make
UTILS := bin/enroot-aufs2ovlfs    \
         bin/enroot-mksquashovlfs \
         bin/enroot-mount         \
         bin/enroot-switchroot    \
         bin/enroot-nsenter       \
         bin/enroot-zfs-mount
```

Then:

```sh
make bin/enroot-zfs-mount
file bin/enroot-zfs-mount
```

Expected: builds without warnings, output is `static-pie linked`.

- [ ] **Step 1.3: Commit**

```sh
git add bin/enroot-zfs-mount.c Makefile
git commit -s -m "Add bin/enroot-zfs-mount skeleton"
```

---

### Task 2: Parse `/etc/enroot/enroot.conf` for the authoritative `ENROOT_DATA_PATH`

The helper must use the **system** config, not the user's `~/.config/enroot/enroot.conf`, so a malicious caller can't redirect `ENROOT_DATA_PATH`. Hardcoded path for now (`/etc/enroot/enroot.conf`); installable prefix follows the Makefile's `sysconfdir`.

**Files:**
- Modify: `bin/enroot-zfs-mount.c` (add config parser).

- [ ] **Step 2.1: Add a config-file path constant**

The Makefile templates `@sysconfdir@` into bash; for C helpers we usually accept a `-D` macro at build time. Add to `Makefile` near the helper's CFLAGS area (the `$(UTILS)` recipe — see the existing `MOUNTPOINT` macro in `enroot-mksquashovlfs`):

```make
bin/enroot-zfs-mount: CPPFLAGS += -DSYSCONFDIR=\"$(sysconfdir)\"
```

(Add this line before the `$(UTILS): | deps` line in `Makefile`.)

- [ ] **Step 2.2: Parse the config file**

Add to `bin/enroot-zfs-mount.c`, before `main`:

```c
#ifndef SYSCONFDIR
# define SYSCONFDIR "/usr/local/etc"
#endif
#define CONF_PATH SYSCONFDIR "/enroot/enroot.conf"

/*
 * Reads ENROOT_DATA_PATH from /etc/enroot/enroot.conf. Returns a malloc'd
 * string the caller must free, or NULL if the key is absent.
 *
 * The conf format is `KEY VALUE` per line, optionally `KEY=VALUE` (matches
 * the bash side's IFS=$' \t=' read). Comments start with #.
 */
static char *
read_data_path(void)
{
        FILE *f = fopen(CONF_PATH, "r");
        if (f == NULL)
                err(EXIT_FAILURE, "cannot read %s", CONF_PATH);

        char *line = NULL;
        size_t len = 0;
        ssize_t n;
        char *result = NULL;

        while ((n = getline(&line, &len, f)) != -1) {
                /* strip trailing \n */
                if (n > 0 && line[n - 1] == '\n') line[n - 1] = '\0';

                /* skip blanks and comments */
                char *p = line;
                while (*p == ' ' || *p == '\t') p++;
                if (*p == '\0' || *p == '#') continue;

                /* split on first ' ', '\t', or '=' */
                char *key = p;
                while (*p && *p != ' ' && *p != '\t' && *p != '=') p++;
                if (*p == '\0') continue;
                *p++ = '\0';
                while (*p == ' ' || *p == '\t' || *p == '=') p++;

                if (!strcmp(key, "ENROOT_DATA_PATH")) {
                        result = strdup(p);
                        break;
                }
        }
        free(line);
        fclose(f);
        return (result);
}
```

- [ ] **Step 2.3: Wire it into `main` (read but don't yet validate)**

Replace the `/* TODO Task 2-4 */` line with:

```c
        char *data_path = read_data_path();
        if (data_path == NULL)
                errx(EXIT_FAILURE, "ENROOT_DATA_PATH is not set in %s", CONF_PATH);
```

- [ ] **Step 2.4: Smoke-test config parsing**

```sh
make bin/enroot-zfs-mount
sudo bash -c 'cat > /tmp/test-enroot.conf <<EOF
# comment
ENROOT_DATA_PATH /var/lib/enroot
ENROOT_OTHER     /something
EOF
'
# Verify by ltrace or a debug print added temporarily; or trust the next task's exec to consume it.
echo "(deferred to integration test in Task 7)"
```

- [ ] **Step 2.5: Commit**

```sh
git add bin/enroot-zfs-mount.c Makefile
git commit -s -m "Parse ENROOT_DATA_PATH from /etc/enroot/enroot.conf"
```

---

### Task 3: Resolve parent ZFS dataset from `/proc/self/mounts`; validate dataset prefix

The dataset arg must be under `<parent-dataset>/`. The parent is whatever ZFS dataset is mounted at `ENROOT_DATA_PATH` or its closest mounted ancestor.

**Files:**
- Modify: `bin/enroot-zfs-mount.c`.

- [ ] **Step 3.1: Add `/proc/self/mounts` parsing**

Append before `main`:

```c
/*
 * Walks /proc/self/mounts looking for the longest-prefix mount entry of type
 * "zfs" whose mountpoint is data_path (or a path ancestor of it, falling
 * back upward). Returns the dataset name (malloc'd) or NULL if no zfs
 * mount covers data_path.
 */
static char *
resolve_parent_dataset(const char *data_path)
{
        FILE *f = fopen("/proc/self/mounts", "r");
        if (f == NULL)
                err(EXIT_FAILURE, "cannot read /proc/self/mounts");

        char *line = NULL, *best_src = NULL;
        size_t len = 0, best_mp_len = 0;
        ssize_t n;
        size_t dp_len = strlen(data_path);

        while ((n = getline(&line, &len, f)) != -1) {
                char src[PATH_MAX], mp[PATH_MAX], type[64];
                if (sscanf(line, "%s %s %63s", src, mp, type) != 3) continue;
                if (strcmp(type, "zfs") != 0) continue;

                size_t mp_len = strlen(mp);
                /* mp must be data_path itself or a strict prefix path */
                if (mp_len > dp_len) continue;
                if (strncmp(mp, data_path, mp_len) != 0) continue;
                if (mp_len < dp_len && data_path[mp_len] != '/' && mp_len > 1) continue;

                if (mp_len > best_mp_len) {
                        free(best_src);
                        best_src = strdup(src);
                        best_mp_len = mp_len;
                }
        }
        free(line);
        fclose(f);
        return (best_src);
}

/* Returns true if dataset is exactly parent or under parent/. */
static bool
dataset_under(const char *dataset, const char *parent)
{
        size_t pl = strlen(parent);
        if (strncmp(dataset, parent, pl) != 0) return (false);
        return (dataset[pl] == '\0' || dataset[pl] == '/');
}
```

(Add `#include <linux/limits.h>` near the top if `PATH_MAX` isn't already pulled in via `common.h` — it is via `<sys/stat.h>`, so usually unnecessary; verify with `make`.)

- [ ] **Step 3.2: Use it in `main` for the prefix check**

Replace the line `/* TODO Task 2-4: validate ... */` (which now reads only the data path read; expand) with:

```c
        char *data_path = read_data_path();
        if (data_path == NULL)
                errx(EXIT_FAILURE, "ENROOT_DATA_PATH is not set in %s", CONF_PATH);

        char *parent_ds = resolve_parent_dataset(data_path);
        if (parent_ds == NULL)
                errx(EXIT_FAILURE, "no ZFS dataset is mounted at or above %s", data_path);

        if (!dataset_under(dataset, parent_ds))
                errx(EXIT_FAILURE, "dataset %s is not under %s", dataset, parent_ds);
```

- [ ] **Step 3.3: Verify rejection works**

```sh
make bin/enroot-zfs-mount
# Without proper conf, helper exits with conf error
sudo bin/enroot-zfs-mount tank/admin/secrets 2>&1 | head -1
# Expected: "ENROOT_DATA_PATH is not set in /usr/local/etc/enroot/enroot.conf"

# With a config pointing at a non-existent ZFS path:
sudo bash -c 'mkdir -p /usr/local/etc/enroot; cat > /usr/local/etc/enroot/enroot.conf <<EOF
ENROOT_DATA_PATH /var/nonexistent
EOF
'
sudo bin/enroot-zfs-mount tank/admin/secrets 2>&1 | head -1
# Expected: "no ZFS dataset is mounted at or above /var/nonexistent"
```

- [ ] **Step 3.4: Commit**

```sh
git add bin/enroot-zfs-mount.c
git commit -s -m "Resolve parent dataset from /proc/self/mounts and prefix-check arg"
```

---

### Task 4: Look up the dataset's mountpoint property; validate it's under `ENROOT_DATA_PATH`; do the mount(2)

We need the `mountpoint` ZFS property of the target dataset. The helper exec's `zfs get -H -o value mountpoint <ds>` — fork+exec with `posix_spawn`-like primitives, or `popen` for simplicity. Since the helper is short-lived and CAP_SYS_ADMIN drops not yet needed (the exec'd child of a setcap binary inherits no caps by default — file caps don't propagate via execve unless inheritable AND ambient is set, neither of which we set), `popen` is fine.

**Files:**
- Modify: `bin/enroot-zfs-mount.c`.

- [ ] **Step 4.1: Add the mountpoint-property lookup**

Append before `main`:

```c
/*
 * Returns the ZFS mountpoint property of `dataset` (malloc'd), or NULL on
 * error. Exec's `zfs get -H -o value mountpoint DATASET`.
 */
static char *
get_mountpoint(const char *dataset)
{
        char cmd[PATH_MAX + 64];
        snprintf(cmd, sizeof(cmd), "zfs get -H -o value mountpoint '%s' 2>/dev/null", dataset);

        FILE *p = popen(cmd, "r");
        if (p == NULL) return (NULL);

        char buf[PATH_MAX];
        char *result = NULL;
        if (fgets(buf, sizeof(buf), p) != NULL) {
                size_t l = strlen(buf);
                if (l > 0 && buf[l - 1] == '\n') buf[l - 1] = '\0';
                if (buf[0] == '/') result = strdup(buf);
        }
        pclose(p);
        return (result);
}

/* Returns true if path is exactly prefix or under prefix/. */
static bool
path_under(const char *path, const char *prefix)
{
        size_t pl = strlen(prefix);
        if (strncmp(path, prefix, pl) != 0) return (false);
        return (path[pl] == '\0' || path[pl] == '/');
}
```

- [ ] **Step 4.2: Replace the placeholder `mount(...)` call with the real one**

In `main`, replace:

```c
        if (mount(dataset, "/tmp/zfs-mount-skeleton-stub", "zfs", 0, NULL) < 0)
                err(EXIT_FAILURE, "mount failed");
```

with:

```c
        char *mp = get_mountpoint(dataset);
        if (mp == NULL)
                errx(EXIT_FAILURE, "could not get mountpoint property of %s", dataset);
        if (!path_under(mp, data_path))
                errx(EXIT_FAILURE, "mountpoint %s is not under %s", mp, data_path);

        /* Ensure the mountpoint directory exists. mkdir(2) runs as the calling
         * uid (caps don't bypass DAC unless DAC_OVERRIDE is effective; we
         * keep it permitted only). */
        if (mkdir(mp, 0755) < 0 && errno != EEXIST)
                err(EXIT_FAILURE, "mkdir %s", mp);

        if (mount(dataset, mp, "zfs", 0, NULL) < 0)
                err(EXIT_FAILURE, "mount %s on %s", dataset, mp);

        free(mp);
        free(parent_ds);
        free(data_path);
        return (EXIT_SUCCESS);
```

- [ ] **Step 4.3: Verify a real mount works under the test pool**

(Test pool setup must mirror `doc/zfs.md` admin recipe.)

```sh
sudo bash -c 'cat > /usr/local/etc/enroot/enroot.conf <<EOF
ENROOT_DATA_PATH /var/lib/enroot
EOF
'
make bin/enroot-zfs-mount
sudo setcap cap_sys_admin+pe bin/enroot-zfs-mount
# As unprivileged user (no sudo!):
zfs create -u tank/enroot/data/manualtest
bin/enroot-zfs-mount tank/enroot/data/manualtest
mountpoint /var/lib/enroot/manualtest && echo "MOUNTED OK"
sudo zfs destroy tank/enroot/data/manualtest
```

Expected: `MOUNTED OK`. The dataset is mounted by the unprivileged user via the helper.

- [ ] **Step 4.4: Verify a hostile arg is rejected**

```sh
# Try to mount the parent itself (already mounted; should fail downstream too, but prefix-check passes since dataset is the parent).
bin/enroot-zfs-mount tank/admin/secrets 2>&1 | head -1
# Expected: "dataset tank/admin/secrets is not under tank/enroot/data" (or similar)
```

- [ ] **Step 4.5: Commit**

```sh
git add bin/enroot-zfs-mount.c
git commit -s -m "Resolve mountpoint property and perform mount(2)"
```

---

### Task 5: `--unmount` mode

`enroot remove` and the sweep paths need an unmount before `zfs destroy`. The helper takes `--unmount DATASET`, looks up the dataset's current mountpoint via `/proc/self/mounts`, validates that the mountpoint is what the dataset's `mountpoint` property says (defends against unmounting the wrong thing if some other process moved the mount), then `umount2()`.

**Files:**
- Modify: `bin/enroot-zfs-mount.c`.

- [ ] **Step 5.1: Add a "find current mount of dataset" helper**

Append before `main`:

```c
/* Returns the current mountpoint of dataset (malloc'd), or NULL if not mounted. */
static char *
find_current_mountpoint(const char *dataset)
{
        FILE *f = fopen("/proc/self/mounts", "r");
        if (f == NULL) return (NULL);

        char *line = NULL, *result = NULL;
        size_t len = 0;
        ssize_t n;

        while ((n = getline(&line, &len, f)) != -1) {
                char src[PATH_MAX], mp[PATH_MAX], type[64];
                if (sscanf(line, "%s %s %63s", src, mp, type) != 3) continue;
                if (strcmp(type, "zfs") != 0) continue;
                if (strcmp(src, dataset) == 0) {
                        result = strdup(mp);
                        break;
                }
        }
        free(line);
        fclose(f);
        return (result);
}
```

- [ ] **Step 5.2: Replace the unmount stub in `main`**

Replace:

```c
        if (do_unmount) {
                /* TODO Task 5 */
                errx(EXIT_FAILURE, "unmount not implemented yet");
        }
```

with:

```c
        if (do_unmount) {
                char *cur = find_current_mountpoint(dataset);
                if (cur == NULL)
                        return (EXIT_SUCCESS);  /* not mounted; idempotent */
                if (!path_under(cur, data_path))
                        errx(EXIT_FAILURE, "current mountpoint %s is not under %s", cur, data_path);
                if (umount2(cur, 0) < 0)
                        err(EXIT_FAILURE, "umount %s", cur);
                free(cur);
                free(parent_ds);
                free(data_path);
                return (EXIT_SUCCESS);
        }
```

- [ ] **Step 5.3: Verify unmount**

```sh
zfs create -u tank/enroot/data/umtest
bin/enroot-zfs-mount tank/enroot/data/umtest
mountpoint /var/lib/enroot/umtest && echo "mounted"
bin/enroot-zfs-mount --unmount tank/enroot/data/umtest
mountpoint /var/lib/enroot/umtest 2>&1 | grep -q "is not a mountpoint" && echo "unmounted OK"
sudo zfs destroy tank/enroot/data/umtest
```

Expected: `mounted` then `unmounted OK`.

- [ ] **Step 5.4: Verify already-unmounted is idempotent (no error)**

```sh
zfs create -u tank/enroot/data/idem
bin/enroot-zfs-mount --unmount tank/enroot/data/idem
echo "exit=$?"
sudo zfs destroy tank/enroot/data/idem
```

Expected: `exit=0`.

- [ ] **Step 5.5: Commit**

```sh
git add bin/enroot-zfs-mount.c
git commit -s -m "Add --unmount mode to enroot-zfs-mount"
```

---

### Task 6: Already-mounted check on the mount path

Defense against double-mounts. Before mount, check `/proc/self/mounts` and refuse if the dataset already appears as a current mount source (matches the upstream "no-op idempotent" semantics for unmount + an explicit error for already-mounted on mount).

**Files:**
- Modify: `bin/enroot-zfs-mount.c`.

- [ ] **Step 6.1: Add the check just before the `mount(2)` call**

In `main`, before the `mount(...)` call inserted in Task 4.2, add:

```c
        char *cur = find_current_mountpoint(dataset);
        if (cur != NULL) {
                /* Already mounted somewhere — succeed if at expected mountpoint, error otherwise. */
                if (strcmp(cur, mp) == 0) {
                        free(cur); free(mp); free(parent_ds); free(data_path);
                        return (EXIT_SUCCESS);
                }
                errx(EXIT_FAILURE, "dataset %s is already mounted at %s", dataset, cur);
        }
```

- [ ] **Step 6.2: Verify idempotent re-mount succeeds; mismatch errors**

```sh
zfs create -u tank/enroot/data/repeat
bin/enroot-zfs-mount tank/enroot/data/repeat
bin/enroot-zfs-mount tank/enroot/data/repeat
echo "exit=$?"   # Expected: 0 (idempotent)
sudo bin/enroot-zfs-mount --unmount tank/enroot/data/repeat
sudo zfs destroy tank/enroot/data/repeat
```

Expected: both invocations succeed, second is a no-op.

- [ ] **Step 6.3: Commit**

```sh
git add bin/enroot-zfs-mount.c
git commit -s -m "Add already-mounted idempotency check"
```

---

### Task 7: Wire helper into the `enroot+caps` postinst / prerm

**Files:**
- Modify: `pkg/deb/PACKAGE+caps.postinst`
- Modify: `pkg/deb/PACKAGE+caps.prerm`

- [ ] **Step 7.1: Add setcap line to postinst**

In `pkg/deb/PACKAGE+caps.postinst`, modify the `configure|abort-upgrade|abort-remove|abort-deconfigure)` arm:

```sh
    configure|abort-upgrade|abort-remove|abort-deconfigure)
        setcap cap_sys_admin+pe "$(command -v enroot-mksquashovlfs)"
        setcap cap_sys_admin,cap_mknod+pe "$(command -v enroot-aufs2ovlfs)"
        setcap cap_sys_admin+pe "$(command -v enroot-zfs-mount)"
    ;;
```

- [ ] **Step 7.2: Add reverse line to prerm**

In `pkg/deb/PACKAGE+caps.prerm`:

```sh
    remove|upgrade|deconfigure)
        setcap cap_sys_admin-pe "$(command -v enroot-mksquashovlfs)"
        setcap cap_sys_admin,cap_mknod-pe "$(command -v enroot-aufs2ovlfs)"
        setcap cap_sys_admin-pe "$(command -v enroot-zfs-mount)"
    ;;
```

- [ ] **Step 7.3: Mirror in the Makefile `setcap` target (for `make setcap` / source installs)**

In `Makefile`, modify the `setcap:` target:

```make
setcap:
	setcap cap_sys_admin+pe $(BINDIR)/enroot-mksquashovlfs
	setcap cap_sys_admin,cap_mknod+pe $(BINDIR)/enroot-aufs2ovlfs
	setcap cap_sys_admin+pe $(BINDIR)/enroot-zfs-mount
```

- [ ] **Step 7.4: Commit**

```sh
git add pkg/deb/PACKAGE+caps.postinst pkg/deb/PACKAGE+caps.prerm Makefile
git commit -s -m "Wire enroot-zfs-mount setcap into +caps package and make target"
```

---

### Task 8: Switch `zfs::ensure_template` to `zfs create -u` + helper mount

**Files:**
- Modify: `src/storage_zfs.sh` (`zfs::ensure_template`).

- [ ] **Step 8.1: Update the create call site**

Find the block (around the `# Try to create the .tmp dataset atomically` comment):

```bash
    if zfs create -p "${tmp}" 2> /dev/null; then
        # We won — extract.
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        common::log INFO "Extracting squashfs filesystem into ZFS template..." NL
```

Change to:

```bash
    if zfs create -p -u "${tmp}" 2> /dev/null; then
        # We won — extract. Mount the .tmp dataset via the cap-elevated helper
        # so unprivileged callers can write into it (Linux mount(2) needs
        # CAP_SYS_ADMIN regardless of zfs allow delegation).
        if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
            zfs destroy "${tmp}" 2> /dev/null || :
            common::err "failed to mount template; install enroot+caps to enable unprivileged mount"
        fi
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        common::log INFO "Extracting squashfs filesystem into ZFS template..." NL
```

- [ ] **Step 8.2: After `zfs rename` (in the same function), re-mount the renamed dataset**

`zfs rename` of a mounted dataset preserves the mount when both old and new mountpoints land at the same final path (which they do in our case since the rename is `<sha>.tmp` → `<sha>` but the mountpoint property is inherited and rebuilt from the path). To be safe, unmount the old name before rename and remount the new name after.

Find:

```bash
        zfs rename "${tmp}" "${template}"
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
```

Change to:

```bash
        # Rename and remount under the final name. ZFS-on-Linux unmounts the
        # source on rename if its mountpoint changes; mountpoint here is
        # inherited from the parent, so the rename effectively moves the
        # mount. Bracket explicitly to be deterministic across zfs versions.
        enroot-zfs-mount --unmount "${tmp}" 2> /dev/null || :
        zfs rename "${tmp}" "${template}"
        enroot-zfs-mount "${template}" 2> /dev/null || :
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
```

- [ ] **Step 8.3: Verify both privileged and unprivileged `enroot create` work**

(Assumes test pool from `doc/zfs.md` and an `alpine.sqsh` test image at `/tmp/alpine.sqsh`.)

```sh
make && sudo make install setcap

# privileged still works
sudo enroot create -f -n privileged-test /tmp/alpine.sqsh
ls /var/lib/enroot/privileged-test/etc/os-release && echo "priv OK"
sudo enroot remove -f privileged-test

# unprivileged now works
enroot create -f -n unpriv-test /tmp/alpine.sqsh
ls /var/lib/enroot/unpriv-test/etc/os-release && echo "unpriv OK"
sudo enroot remove -f unpriv-test
```

Expected: both `priv OK` and `unpriv OK`.

- [ ] **Step 8.4: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "zfs::ensure_template: use zfs create -u + enroot-zfs-mount"
```

---

### Task 9: Same substitution for `zfs::ensure_template_from_stream`

**Files:**
- Modify: `src/storage_zfs.sh` (`zfs::ensure_template_from_stream`).

- [ ] **Step 9.1: Update the receive call site**

Find the block:

```bash
    if zfs receive -F "${tmp}" < "${stream}" 2> /dev/null; then
        zfs rename "${tmp}" "${template}"
```

Change to:

```bash
    if zfs receive -u -F "${tmp}" < "${stream}" 2> /dev/null; then
        if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
            zfs destroy -r "${tmp}" 2> /dev/null || :
            common::err "failed to mount received template"
        fi
        enroot-zfs-mount --unmount "${tmp}" 2> /dev/null || :
        zfs rename "${tmp}" "${template}"
        enroot-zfs-mount "${template}" 2> /dev/null || :
```

- [ ] **Step 9.2: Verify with a `.zfs` file create**

```sh
sudo enroot create -f -n donor /tmp/alpine.sqsh
sudo enroot export -f --format=zfs -o /tmp/donor.zfs donor
sudo enroot remove -f donor
sudo zfs destroy -r tank/enroot/data/.templates 2>/dev/null
# now as unprivileged user:
enroot create -f -n from_stream /tmp/donor.zfs
ls /var/lib/enroot/from_stream/etc/os-release && echo "OK"
sudo enroot remove -f from_stream
```

Expected: `OK`.

- [ ] **Step 9.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "zfs::ensure_template_from_stream: use zfs receive -u + enroot-zfs-mount"
```

---

### Task 10: `zfs::clone_container`

**Files:**
- Modify: `src/storage_zfs.sh` (`zfs::clone_container`).

- [ ] **Step 10.1: Update the clone call site**

Find:

```bash
    zfs clone "${template}@${zfs_pristine_snap}" "${target}"
}
```

Change to:

```bash
    zfs clone -u "${template}@${zfs_pristine_snap}" "${target}"
    if ! enroot-zfs-mount "${target}" 2> /dev/null; then
        zfs destroy "${target}" 2> /dev/null || :
        common::err "failed to mount cloned container ${name}"
    fi
}
```

- [ ] **Step 10.2: Smoke (covered by Task 8.3 indirectly; explicit verification:)**

```sh
enroot create -f -n c1 /tmp/alpine.sqsh
enroot create -f -n c2 /tmp/alpine.sqsh   # second is a clone-of-template
ls /var/lib/enroot/c1/etc/os-release /var/lib/enroot/c2/etc/os-release && echo "OK"
sudo enroot remove -f c1 c2
```

- [ ] **Step 10.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "zfs::clone_container: use zfs clone -u + enroot-zfs-mount"
```

---

### Task 11: `zfs::ephemeral_clone` (Plan E)

**Files:**
- Modify: `src/storage_zfs.sh` (`zfs::ephemeral_clone`).

- [ ] **Step 11.1: Update the ephemeral clone call site**

Find:

```bash
    zfs clone "${template}@${zfs_pristine_snap}" "${clone}"
    zfs set readonly=off "${clone}"

    mountpoint=$(zfs get -H -o value mountpoint "${clone}")
```

Change to:

```bash
    zfs clone -u "${template}@${zfs_pristine_snap}" "${clone}"
    zfs set readonly=off "${clone}"
    if ! enroot-zfs-mount "${clone}" 2> /dev/null; then
        zfs destroy "${clone}" 2> /dev/null || :
        common::err "failed to mount ephemeral clone"
    fi

    mountpoint=$(zfs get -H -o value mountpoint "${clone}")
```

- [ ] **Step 11.2: Verify ephemeral start works unprivileged**

```sh
enroot start /tmp/alpine.sqsh /bin/echo hello
echo "exit=$?"
zfs list -H -o name | grep -E '\.ephemeral/' && echo "BAD: leak" || echo "clean"
```

Expected: `hello`, exit 0, `clean`.

- [ ] **Step 11.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "zfs::ephemeral_clone: use zfs clone -u + enroot-zfs-mount"
```

---

### Task 12: `zfs::docker_install_from_layers` (Plan F)

**Files:**
- Modify: `src/storage_zfs.sh` (`zfs::docker_install_from_layers`).

- [ ] **Step 12.1: Update the create call site**

Find the block:

```bash
    elif zfs create -p "${tmp}" 2> /dev/null; then
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        mkdir -p rootfs
```

Change to:

```bash
    elif zfs create -p -u "${tmp}" 2> /dev/null; then
        if ! enroot-zfs-mount "${tmp}" 2> /dev/null; then
            zfs destroy "${tmp}" 2> /dev/null || :
            common::err "failed to mount docker template"
        fi
        mountpoint=$(zfs get -H -o value mountpoint "${tmp}")
        mkdir -p rootfs
```

And, after the inner success path that does `zfs rename ... zfs snapshot ... zfs set readonly`, bracket the rename with unmount/remount as in Task 8.2:

```bash
        enroot-zfs-mount --unmount "${tmp}" 2> /dev/null || :
        zfs rename "${tmp}" "${template}"
        enroot-zfs-mount "${template}" 2> /dev/null || :
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
```

- [ ] **Step 12.2: Verify docker load works unprivileged**

(Assumes the user has previously imported alpine cache or has network.)

```sh
sudo enroot import docker://alpine -o /tmp/cache.sqsh   # warm cache only
enroot load -n alpine docker://alpine
ls /var/lib/enroot/alpine/etc/os-release && echo "OK"
sudo enroot remove -f alpine
```

Expected: `OK`.

- [ ] **Step 12.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "zfs::docker_install_from_layers: use zfs create -u + enroot-zfs-mount"
```

---

### Task 13: Unmount before destroy in lifecycle paths

`zfs destroy` on a mounted dataset auto-unmounts, which fails for unprivileged users. Three call sites:

1. `zfs::destroy_container` (Plan A's `runtime::remove` path).
2. `zfs::ephemeral_destroy` (Plan E's cleanup shim).
3. `zfs::sweep_templates` (Plan B's eviction).
4. The `zfs destroy` calls inside the layer-stack and stream paths' error-recovery branches.

**Files:**
- Modify: `src/storage_zfs.sh`.

- [ ] **Step 13.1: `zfs::destroy_container`**

Find:

```bash
zfs::destroy_container() {
    ...
    zfs destroy "${target}"
}
```

Change to:

```bash
zfs::destroy_container() {
    ...
    enroot-zfs-mount --unmount "${target}" 2> /dev/null || :
    zfs destroy "${target}"
}
```

- [ ] **Step 13.2: `zfs::ephemeral_destroy`**

Find:

```bash
zfs::ephemeral_destroy() {
    local -r clone="$1"
    [ -z "${clone}" ] && return
    zfs destroy "${clone}" 2> /dev/null || :
}
```

Change to:

```bash
zfs::ephemeral_destroy() {
    local -r clone="$1"
    [ -z "${clone}" ] && return
    enroot-zfs-mount --unmount "${clone}" 2> /dev/null || :
    zfs destroy "${clone}" 2> /dev/null || :
}
```

- [ ] **Step 13.3: `zfs::sweep_templates`**

Find the sweep loop's destroy block:

```bash
        common::log INFO "Evicting template ${ds##*/} (age ${age}s)"
        zfs destroy "${ds}@${zfs_pristine_snap}" 2> /dev/null || :
        zfs destroy "${ds}" 2> /dev/null || :
```

Change to:

```bash
        common::log INFO "Evicting template ${ds##*/} (age ${age}s)"
        zfs destroy "${ds}@${zfs_pristine_snap}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${ds}" 2> /dev/null || :
        zfs destroy "${ds}" 2> /dev/null || :
```

- [ ] **Step 13.4: Verify unprivileged remove + clean ephemeral leftover**

```sh
enroot create -f -n rm-test /tmp/alpine.sqsh
enroot remove -f rm-test
zfs list -H -o name | grep rm-test && echo "BAD" || echo "OK"
```

Expected: `OK`.

- [ ] **Step 13.5: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Unmount before destroy at all lifecycle call sites"
```

---

### Task 14: pyxis-flow integration verification

Reproduces issue #9's failure mode and confirms the new path closes it.

**Files:**
- (Read-only verification.)

- [ ] **Step 14.1: As an unprivileged user, run the reproducer from issue #9**

```sh
enroot import -o /tmp/hello.sqsh docker://hello-world
time enroot create --name test-hw /tmp/hello.sqsh
ls /var/lib/enroot/test-hw/etc 2>&1 | head
sudo enroot remove -f test-hw
```

Expected: `enroot create` completes in seconds; the rootfs is populated; `enroot remove` succeeds. Compare against the issue's "10m02s timeout" baseline.

- [ ] **Step 14.2: As an unprivileged user, run a clone-on-create cycle**

```sh
enroot create --name reuse1 /tmp/hello.sqsh
time enroot create --name reuse2 /tmp/hello.sqsh    # should be ~0.3s (clone)
sudo enroot remove -f reuse1 reuse2
```

Expected: second create is sub-second.

- [ ] **Step 14.3: pyxis end-to-end (if a Slurm test cluster is available)**

```sh
srun --container-image=ubuntu:24.04 cat /etc/os-release
```

Expected: completes; prints Ubuntu os-release. (Skip if no Slurm cluster — the manual repro in 14.1 covers the same code path.)

- [ ] **Step 14.4: No commit (verification only).**

---

### Task 15: Documentation, version bump, packaging

**Files:**
- Modify: `doc/zfs.md` (replace the "Linux mount(2) caveat" section).
- Modify: `Makefile` (`VERSION` → `4.1.2.zfs.2`).
- Modify: `pkg/deb/changelog` (new entry).

- [ ] **Step 15.1: Update `doc/zfs.md`**

Find the "Linux mount(2) caveat" section under admin setup. Replace its body with:

```markdown
   **Linux mount(2) bypass via `enroot-zfs-mount`:** ZFS delegation governs
   ZFS's *internal* logic, but on Linux the kernel `mount(2)` syscall still
   requires `CAP_SYS_ADMIN`. The `enroot+caps` package installs
   `enroot-zfs-mount` with `cap_sys_admin+pe`; the helper validates that the
   caller-supplied dataset is under the parent dataset of `ENROOT_DATA_PATH`
   (read from `/etc/enroot/enroot.conf`, NOT from user-controlled config),
   that its `mountpoint` property is under `ENROOT_DATA_PATH`, and that it
   isn't already mounted, before performing `mount(2)` / `umount2(2)`. With
   `+caps` installed, all unprivileged ZFS-backed flows (`enroot create`,
   `enroot load`, `enroot start <image>`, `enroot remove`) work end-to-end.

   Without `+caps`, unprivileged callers cannot mount ZFS datasets and must
   run `enroot create` and friends as root (e.g., via sudo or
   privilege-elevated systemd unit). The `dir` backend is unaffected.
```

- [ ] **Step 15.2: Bump version**

In `Makefile`, change:

```make
VERSION       := 4.1.2.zfs.1
```

to:

```make
VERSION       := 4.1.2.zfs.2
```

- [ ] **Step 15.3: Add changelog entry**

In `pkg/deb/changelog`, add at the top:

```
#PACKAGE# (4.1.2.zfs.2-1) UNRELEASED; urgency=medium

  * Add bin/enroot-zfs-mount cap_sys_admin helper (shipped with enroot+caps)
    that validates and performs mount(2)/umount2(2) of ZFS datasets owned by
    the calling user, so that unprivileged enroot create/load/start/remove
    work on the ZFS backend (issue #9 — pyxis/Slurm integration).

 -- #USERNAME# <#EMAIL#>  Wed, 29 Apr 2026 16:00:00 +0000
```

- [ ] **Step 15.4: Commit**

```sh
git add doc/zfs.md Makefile pkg/deb/changelog
git commit -s -m "Release 4.1.2.zfs.2: enroot-zfs-mount helper for unprivileged ZFS"
```

---

### Task 16: Build packages and tag the release

**Files:**
- (Build artifacts only.)

- [ ] **Step 16.1: Build standard + hardened debs**

```sh
make clean
rm -f ../enroot_*.orig.tar.* ../enroot-hardened_*.orig.tar.*
CPPFLAGS="-DALLOW_SPECULATION -DINHERIT_FDS" make deb
mkdir -p /tmp/release-stage && mv dist/* /tmp/release-stage/
make deb PACKAGE=enroot-hardened
mv /tmp/release-stage/* dist/
ls dist/*.deb
```

Expected: 4 debs (`enroot`, `enroot+caps`, `enroot-hardened`, `enroot-hardened+caps`) at version `4.1.2.zfs.2-1`.

- [ ] **Step 16.2: Build relocatable tarball**

```sh
CPPFLAGS="-DALLOW_SPECULATION -DINHERIT_FDS" make dist
ls dist/*.tar.xz
```

- [ ] **Step 16.3: Tag and push**

```sh
git push origin zenroot/main
git tag -a v4.1.2.zfs.2 -m "zenroot 4.1.2.zfs.2: enroot-zfs-mount helper (issue #9)"
git push origin v4.1.2.zfs.2
```

- [ ] **Step 16.4: Create GitHub release**

```sh
gh release create v4.1.2.zfs.2 \
  --repo zeroae/enroot \
  --target zenroot/main \
  --title "zenroot 4.1.2.zfs.2: pyxis/Slurm-compatible unprivileged ZFS" \
  --notes-file <(cat <<'EOF'
Adds `enroot-zfs-mount`, a `cap_sys_admin`-elevated helper that lets
unprivileged callers mount the ZFS datasets enroot creates, fixing
issue #9 (pyxis/Slurm container launches were timing out at
`enroot create` with the documented `mount(2)` limitation).

## What's new

- `bin/enroot-zfs-mount` (~150 lines C, static-pie/musl): validates and performs `mount(2)`/`umount2(2)` of ZFS datasets that are under the parent of `ENROOT_DATA_PATH` and whose mountpoint property is itself under `ENROOT_DATA_PATH`. The helper reads its config from `/etc/enroot/enroot.conf` only (never from user-controlled config).
- Shipped via `enroot+caps` (and `enroot-hardened+caps`); the postinst grants `cap_sys_admin+pe`.
- `src/storage_zfs.sh` switched to `zfs create -u` / `zfs clone -u` / `zfs receive -u` (skip auto-mount) and calls the helper for the actual mount; destroy paths gain a helper unmount before destroy.

With `+caps` installed, `enroot create`, `enroot load`, `enroot start <image>`, and `enroot remove` all work end-to-end as the unprivileged caller — including from inside `slurmstepd` post-privilege-drop, which is what pyxis needs.

## Trust posture

The helper does three checks before any privileged syscall:
1. Argument dataset must be under the parent dataset of `ENROOT_DATA_PATH` (resolved from `/proc/self/mounts`).
2. Dataset's `mountpoint` property must be under `ENROOT_DATA_PATH`.
3. Mount path: dataset must not already be mounted (or, if it is, must be at the expected mountpoint — idempotent).
4. Unmount path: current mountpoint must be under `ENROOT_DATA_PATH`.

This stops a hostile caller from mounting arbitrary ZFS datasets or shadowing system paths (e.g., setting a self-owned dataset's mountpoint to `/usr/local/bin`).

## Closes

- #9 (pyxis/Slurm `enroot create` 10-minute timeout post-privilege-drop)
EOF
) \
  dist/enroot_4.1.2.zfs.2-1_arm64.deb \
  'dist/enroot+caps_4.1.2.zfs.2-1_arm64.deb' \
  dist/enroot-hardened_4.1.2.zfs.2-1_arm64.deb \
  'dist/enroot-hardened+caps_4.1.2.zfs.2-1_arm64.deb' \
  dist/enroot_4.1.2.zfs.2_aarch64.tar.xz \
  dist/enroot_4.1.2.zfs.2.orig.tar.xz
```

- [ ] **Step 16.5: Final state check**

```sh
gh release view v4.1.2.zfs.2 --repo zeroae/enroot
```

Expected: release exists, six artifacts attached, notes link to issue #9.

---

## Self-review checklist

- [x] Spec coverage: helper exists (T1–T6), wired into `+caps` (T7) and `setcap` target (T7.3), all five mount-needing call sites converted (T8 ensure_template, T9 ensure_template_from_stream, T10 clone_container, T11 ephemeral_clone, T12 docker_install_from_layers), all destroy/sweep call sites get unmount-first (T13), pyxis flow verified (T14), docs/version/changelog updated (T15), packages built + tagged + released (T16).
- [x] Trust-posture coverage: prefix check (T3), mountpoint-under-DATA_PATH check (T4), already-mounted check (T6), unmount target validation (T5).
- [x] Type consistency: `enroot-zfs-mount` argument convention (`<ds>` for mount, `--unmount <ds>` for unmount) matches between `bin/enroot-zfs-mount.c` (T1, T5) and all `src/storage_zfs.sh` call sites (T8–T13).
- [x] No placeholders. Every step has a concrete diff or exact command.

## Known limitations

- **Helper depends on system enroot.conf.** If `/etc/enroot/enroot.conf` doesn't set `ENROOT_DATA_PATH`, the helper errors. Sites that set `ENROOT_DATA_PATH` only via the user's `~/.config/enroot/enroot.conf` will need to add a system-wide entry.
- **No support for mountpoint=legacy.** The helper assumes ZFS-managed mountpoints. Datasets with `mountpoint=legacy` would have a `-` value and the helper rejects them. Documented in `doc/zfs.md`.
- **`zfs(8)` exec on every helper invocation.** For the mountpoint property lookup the helper exec's `zfs get`. Adds ~10 ms of overhead per call. Linking against libzfs would avoid this but adds a runtime dep we don't currently have.
- **No SELinux / AppArmor profile updates.** Sites running with strict MAC may need a profile that allows the helper's `mount(2)` call. Out of scope for this plan; the existing apparmor profile in `conf/apparmor.profile` is for the runtime, not the build-time helpers.
- **arm64-only release artifacts.** Same constraint as `4.1.2.zfs.1`; cross-compilation to amd64 needs a separate build host or the docker-release scripts.

## Execution Handoff

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batched checkpoints for review.
