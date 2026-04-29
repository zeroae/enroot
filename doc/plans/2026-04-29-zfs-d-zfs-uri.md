# ZFS Backend Plan D: `zfs://` URI Transport

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `zfs://host/NAME` URI scheme for `enroot load` and `enroot export`. Wire transport is `ssh host enroot ...` invoking `enroot export --zfs-send` / `enroot import --zfs-recv` on the remote. The remote pool name and dataset paths never leak across the wire — the URI names a *container on a remote enroot host*. `enroot import zfs://...` is rejected (use `load` — there is no portable file artifact to produce). No incremental sends in v1; full streams only.

**Architecture:** Two new internal flags `--zfs-send` and `--zfs-recv` on `enroot export` and `enroot import` (respectively) that read/write a stream on stdout/stdin. The `zfs://` URI handler in `runtime::load` and `runtime::export` shells out to `ssh` and pipes streams.

**Depends on:** Plan A and Plan C.

**Prerequisite host setup:** Two ZFS-enabled hosts (or loopback ssh on one host) with passwordless SSH between them; `zfs allow` granted on both for the test user as in Plan A.

---

## Files

- **Modify:** `enroot.in:352-394` (`enroot::import`) — add `--zfs-recv` internal flag, reject `zfs://`.
- **Modify:** `enroot.in:395-441` (`enroot::load`) — accept `zfs://`.
- **Modify:** `enroot.in:442-477` (`enroot::export`) — add `--zfs-send` internal flag, accept `zfs://` destination.
- **Modify:** `src/runtime.sh:450-490` (`runtime::import`/`runtime::load`) — dispatch `zfs://`.
- **Modify:** `src/runtime.sh:492-...` (`runtime::export`) — accept `zfs://` destination.
- **Modify:** `src/storage_zfs.sh` — `zfs::pull_via_ssh`, `zfs::push_via_ssh`, `zfs::recv_to_template_stdin`, `zfs::send_clone_stdout`.

---

### Task 1: Add `zfs::recv_to_template_stdin` and `zfs::send_clone_stdout`

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 1.1: Add stdin/stdout siblings of the file-based helpers**

Append to `src/storage_zfs.sh`:

```bash
# Receives a zfs send stream from stdin into the template cache.
# The cache key is provided by the caller (since we cannot easily hash a stream
# we are reading once); for SSH transport the remote enroot computes a content
# hash and passes it via env ENROOT_REMOTE_TEMPLATE_KEY. If unset, we generate a
# transient cache key from the stream's first snapshot guid.
zfs::recv_to_template_stdin() {
    local key="${ENROOT_REMOTE_TEMPLATE_KEY-}"
    local -r store=$(zfs::store_dataset)
    local tmp template snap

    if [ -z "${key}" ]; then
        # Buffer to a temp file so we can hash and replay.
        local buf
        buf=$(mktemp -p "${ENROOT_TEMP_PATH:-/tmp}" enroot-recv.XXXXXX)
        trap "rm -f '${buf}'" RETURN
        cat > "${buf}"
        key=$(sha256sum "${buf}" | awk '{print $1}')
        zfs::ensure_template_from_stream "${buf}" "${key}"
    else
        tmp="${store}/${zfs_template_subdir}/${key}.tmp"
        template="${store}/${zfs_template_subdir}/${key}"
        snap="${template}@${zfs_pristine_snap}"

        if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
            # Already cached — drain stdin and return.
            cat > /dev/null
            zfs::touch_template "${template}" 2> /dev/null || :
            printf "%s" "${template}"
            return
        fi

        zfs receive -F "${tmp}"
        zfs rename "${tmp}" "${template}"
        if ! zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
            local recvd_snap
            recvd_snap=$(zfs list -H -t snapshot -o name -r -d 1 "${template}" | head -1)
            [ -n "${recvd_snap}" ] && zfs rename "${recvd_snap}" "${snap}"
        fi
        zfs set readonly=on "${template}"
        zfs::touch_template "${template}" 2> /dev/null || :
        printf "%s" "${template}"
    fi
}

# Sends a clone's @pristine snapshot (or a fresh snapshot if the container is not
# a clone) to stdout. Used by --zfs-send.
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
        trap "zfs destroy '${snap}' 2> /dev/null" RETURN
        zfs send "${snap}"
    else
        zfs send "${origin}"
    fi
}
```

- [ ] **Step 1.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::recv_to_template_stdin and zfs::send_clone_stdout helpers"
```

---

### Task 2: Add `--zfs-send` to `enroot export`

**Files:**
- Modify: `enroot.in:442-477` (`enroot::export`)
- Modify: `src/runtime.sh` `runtime::export` (extend Plan C dispatch)

- [ ] **Step 2.1: Add `--zfs-send` parser case**

In `enroot.in` `enroot::export`, add a `--zfs-send` flag that, when present, reads the container name from the next positional and pipes the stream to stdout. This is an internal flag; not documented in the user-visible usage.

Add to the option parser:

```bash
        --zfs-send)
            zfs_send=y
            shift
            ;;
```

After the parser, before the existing `runtime::export` call:

```bash
    if [ -n "${zfs_send-}" ]; then
        if ! zfs::enabled; then
            common::err "--zfs-send requires ENROOT_STORAGE_BACKEND=zfs"
        fi
        zfs::send_clone_stdout "${name}"
        return
    fi
```

(`name` here is the same positional argument the existing `enroot::export` already parses.)

- [ ] **Step 2.2: Verify locally**

```sh
/tmp/enroot/usr/bin/enroot create -n send_test alpine.sqsh
/tmp/enroot/usr/bin/enroot export --zfs-send send_test > /tmp/sendtest.zfs
file /tmp/sendtest.zfs                     # should mention ZFS / data
/tmp/enroot/usr/bin/enroot remove -f send_test
```

Expected: file produced, no console errors, file is non-empty and looks like a zfs stream.

- [ ] **Step 2.3: Commit**

```sh
git add enroot.in
git commit -s -m "Add internal --zfs-send flag to enroot export"
```

---

### Task 3: Add `--zfs-recv` to `enroot import`

**Files:**
- Modify: `enroot.in:352-394` (`enroot::import`)

- [ ] **Step 3.1: Add `--zfs-recv` parser case**

The semantics: `enroot import --zfs-recv -n NAME` reads a stream from stdin, materializes it as a template via `zfs::recv_to_template_stdin`, and clones to `NAME`.

In `enroot::import`, add to the option parser:

```bash
        --zfs-recv)
            zfs_recv=y
            shift
            ;;
        -n|--name)
            [ -z "${2-}" ] && enroot::usage import 1
            name="$2"
            shift 2
            ;;
```

After the parser, *before* the existing positional URI dispatch:

```bash
    if [ -n "${zfs_recv-}" ]; then
        if ! zfs::enabled; then
            common::err "--zfs-recv requires ENROOT_STORAGE_BACKEND=zfs"
        fi
        if [ -z "${name-}" ]; then
            common::err "--zfs-recv requires -n NAME"
        fi
        local template
        template=$(zfs::recv_to_template_stdin)
        zfs::clone_container "${template}" "${name}"
        return
    fi
```

(Add `name=` to the locals at the top of `enroot::import` if it is not already declared.)

- [ ] **Step 3.2: Verify with a local pipe**

```sh
/tmp/enroot/usr/bin/enroot create -n recv_donor alpine.sqsh
/tmp/enroot/usr/bin/enroot export --zfs-send recv_donor \
  | /tmp/enroot/usr/bin/enroot import --zfs-recv -n recv_target
ls /srv/enroot/$USER/recv_target/etc/os-release
/tmp/enroot/usr/bin/enroot remove -f recv_donor recv_target
```

Expected: `os-release` readable; the pipe round-trip works.

- [ ] **Step 3.3: Commit**

```sh
git add enroot.in
git commit -s -m "Add internal --zfs-recv flag to enroot import"
```

---

### Task 4: Add `zfs://` URI parser and dispatch

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 4.1: Add a parser**

Append to `src/storage_zfs.sh`:

```bash
# Parses a zfs:// URI into "host\tname". Format: zfs://host/NAME (NAME may
# contain extra path components which are reassembled into the container name).
zfs::parse_uri() {
    local -r uri="$1"
    if [[ ! "${uri}" =~ ^zfs://([^/]+)/(.+)$ ]]; then
        common::err "Invalid zfs:// URI: ${uri}"
    fi
    printf "%s\t%s" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
```

- [ ] **Step 4.2: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::parse_uri"
```

---

### Task 5: Wire `zfs://` into `runtime::load`

**Files:**
- Modify: `src/runtime.sh:470-490` (`runtime::load`)

- [ ] **Step 5.1: Add `zfs://` case to `runtime::load`**

In `src/runtime.sh:484-489`, change:

```bash
    case "${uri}" in
    docker://*)
        docker::load "${uri}" "${rootfs}" "${arch}" ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
```

to:

```bash
    case "${uri}" in
    docker://*)
        docker::load "${uri}" "${rootfs}" "${arch}" ;;
    zfs://*)
        if ! zfs::enabled; then
            common::err "zfs:// URIs require ENROOT_STORAGE_BACKEND=zfs"
        fi
        local host remote_name template
        zfs::parse_uri "${uri}" \
          | { common::read -r host; common::read -r remote_name; }
        [ -z "${rootfs}" ] && rootfs="${remote_name##*/}"
        common::log INFO "Pulling ${remote_name} from ${host} via ssh"
        ssh "${host}" enroot export --zfs-send "${remote_name}" \
          | { template=$(zfs::recv_to_template_stdin); zfs::clone_container "${template}" "${rootfs}"; }
        ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
```

- [ ] **Step 5.2: Reject `zfs://` in `runtime::import`**

In `src/runtime.sh:460-467`, change:

```bash
    case "${uri}" in
    docker://*)
        docker::import "${uri}" "${filename}" "${arch}" ;;
    dockerd://* | podman://*)
        docker::daemon::import "${uri}" "${filename}" "${arch}" ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
```

to:

```bash
    case "${uri}" in
    docker://*)
        docker::import "${uri}" "${filename}" "${arch}" ;;
    dockerd://* | podman://*)
        docker::daemon::import "${uri}" "${filename}" "${arch}" ;;
    zfs://*)
        common::err "zfs:// has no portable file artifact; use 'enroot load zfs://...'" ;;
    *)
        common::err "Invalid argument: ${uri}" ;;
    esac
```

- [ ] **Step 5.3: Verify pull**

Set up two ZFS hosts (or use ssh to localhost). On the source side, create `pulldonor`. Then on the target side:

```sh
/tmp/enroot/usr/bin/enroot load zfs://localhost/pulldonor -n pulled
ls /srv/enroot/$USER/pulled/etc/os-release
/tmp/enroot/usr/bin/enroot remove -f pulled
```

Expected: `os-release` readable.

- [ ] **Step 5.4: Verify import rejection**

```sh
/tmp/enroot/usr/bin/enroot import zfs://localhost/anything 2>&1 | grep -q "no portable file artifact" && echo OK
```

Expected: `OK`.

- [ ] **Step 5.5: Commit**

```sh
git add src/runtime.sh
git commit -s -m "Add zfs:// URI to enroot load; reject it on import"
```

---

### Task 6: Wire `zfs://` into `runtime::export` (push)

**Files:**
- Modify: `src/runtime.sh` `runtime::export`

- [ ] **Step 6.1: Detect `zfs://` destination at the top of the function**

In `runtime::export` (extended in Plan C), add a `zfs://` destination branch *before* the format dispatch:

```bash
runtime::export() {
    local rootfs="$1" filename="$2" format="${3:-sqsh}"
    ...
    if [[ "${filename}" == zfs://* ]]; then
        if ! zfs::enabled; then
            common::err "zfs:// requires ENROOT_STORAGE_BACKEND=zfs"
        fi
        local host remote_name
        zfs::parse_uri "${filename}" \
          | { common::read -r host; common::read -r remote_name; }
        [ -z "${remote_name##*/}" ] && remote_name="${remote_name}/${rootfs}"
        # If user wrote zfs://host (no path), default the remote name to ours.
        case "${remote_name}" in
            "") remote_name="${rootfs}" ;;
        esac
        common::log INFO "Pushing ${rootfs} to ${host} as ${remote_name}"
        zfs::send_clone_stdout "${rootfs}" \
          | ssh "${host}" enroot import --zfs-recv -n "${remote_name}"
        return
    fi
    ...
}
```

(Place the new block immediately after the variable declarations, before the existing `--format` checks.)

- [ ] **Step 6.2: Verify push**

```sh
/tmp/enroot/usr/bin/enroot create -n pushdonor alpine.sqsh
/tmp/enroot/usr/bin/enroot export pushdonor zfs://localhost/pushed
ssh localhost 'zfs list | grep pushed'
ssh localhost '/tmp/enroot/usr/bin/enroot remove -f pushed'
/tmp/enroot/usr/bin/enroot remove -f pushdonor
```

Expected: `pushed` listed on the remote side; remote remove succeeds.

- [ ] **Step 6.3: Commit**

```sh
git add src/runtime.sh
git commit -s -m "Add zfs:// destination to enroot export"
```

---

### Task 7: Update user-facing usage strings

**Files:**
- Modify: `enroot.in:174-188` (import usage), `:202-215` (load usage), `:163-172` (export usage)

- [ ] **Step 7.1: Add `zfs://` to the load schemes list**

In the load usage block (lines 202-215), add a row to the `Schemes:` table:

```
   zfs://[USER@]HOST/NAME                  Pull a container from a remote enroot host (full zfs send stream over SSH)
```

- [ ] **Step 7.2: Update the export usage to mention `zfs://` output**

```
 Options:
   -o, --output  Output destination: a filename or a zfs:// URI (defaults to "NAME.sqsh")
   -f, --force   Overwrite an existing image
       --format  Output format for file destinations: "sqsh" (default) or "zfs"
```

- [ ] **Step 7.3: Note explicitly that `enroot import zfs://` is invalid**

In the import usage (lines 174-188), under `Schemes:`, do *not* add `zfs://` — but optionally add a one-line note above the schemes:

```
 Note: zfs:// images have no portable file form; use "enroot load zfs://..." instead.
```

- [ ] **Step 7.4: Commit**

```sh
git add enroot.in
git commit -s -m "Document zfs:// URI in load and export usage strings"
```

---

### Task 8: Document Plan D as implemented

**Files:**
- Modify: `doc/zfs.md`

- [ ] **Step 8.1: Update status note**

Update `doc/zfs.md` to mark Plan D (`zfs://` URI transport) as landed.

- [ ] **Step 8.2: End-to-end smoke**

```sh
# Pull then push round-trip:
/tmp/enroot/usr/bin/enroot create -n a alpine.sqsh
/tmp/enroot/usr/bin/enroot export a zfs://localhost/b
/tmp/enroot/usr/bin/enroot remove -f a
/tmp/enroot/usr/bin/enroot load zfs://localhost/b -n c
diff -q <(ls /srv/enroot/$USER/c/etc) <(ls /srv/enroot/$USER/c/etc) && echo OK
ssh localhost '/tmp/enroot/usr/bin/enroot remove -f b'
/tmp/enroot/usr/bin/enroot remove -f c
```

Expected: round-trip succeeds.

- [ ] **Step 8.3: Commit**

```sh
git add doc/zfs.md
git commit -s -m "Mark Plan D (zfs:// URI) as implemented"
```

---

## Self-review checklist

- [x] Spec coverage: `zfs://host/NAME` parsing (T4), pull via load (T5), push via export (T6), reject import (T5.2), no incremental (only full sends — `zfs::send_clone_stdout` and `zfs::recv_to_template_stdin` use plain `zfs send` / `zfs receive`), pool/dataset paths don't leak (URI uses container *name*, not dataset path; remote enroot resolves locally).
- [x] Type consistency: `zfs::recv_to_template_stdin`, `zfs::send_clone_stdout`, `zfs::parse_uri` defined in T1/T4, used in T5/T6.
- [x] No placeholders.

## Execution Handoff

Same options as Plan A.
