# ZFS Backend Plan B: Template Warm/Cold Lifecycle

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Plan A's "destroy template the moment its last clone goes away" with a warm/cold lifecycle. Templates whose refcount hits zero stay around for `ENROOT_TEMPLATE_WARM_SECONDS` (default 7 days), so repeat `create`/`remove` cycles get clone-speed reuse. Cold templates get reaped on every `create`. When the templates dataset crosses `ENROOT_TEMPLATE_PRESSURE_THRESHOLD` (default 0.80) of its quota, warm templates start getting evicted LRU. ENOSPC during extract triggers one retry with all-warm eviction.

**Architecture:** Track `enroot:last_used` (unix epoch) as a ZFS user property on each template. Plug a "sweep" step into `zfs::ensure_template` that runs *before* a new extraction, and a wrapper around the extract/clone path that retries on ENOSPC. Eviction is implicit on `create` only — no daemon, no `enroot gc`.

**Tech Stack:** Same as Plan A. No new tools.

**Depends on:** Plan A landed and on `main`.

**Prerequisite host setup for testing:** Same as Plan A, plus a quota for pressure tests:

```sh
sudo zfs set quota=200M tank/enroot/$USER/.templates  # tight enough to force pressure
```

(The `.templates` dataset is created lazily by Plan A's `zfs::ensure_template`. Run one `enroot create` first if it doesn't exist yet, or `zfs create tank/enroot/$USER/.templates` ahead of time.)

---

## Files

- **Modify:** `enroot.in:96-103` — add two new config knobs.
- **Modify:** `conf/enroot.conf.in` — document the two new knobs.
- **Modify:** `src/storage_zfs.sh` — extend `zfs::ensure_template`, `zfs::clone_container`, `zfs::destroy_container`; add eviction helpers.

---

### Task 1: Wire the two new config knobs

**Files:**
- Modify: `enroot.in:103-104` (config exports)
- Modify: `conf/enroot.conf.in` (after the `ENROOT_STORAGE_BACKEND` block)

- [ ] **Step 1.1: Add the two exports**

In `enroot.in`, immediately after the `config::export ENROOT_STORAGE_BACKEND "dir"` line from Plan A, add:

```bash
config::export ENROOT_TEMPLATE_WARM_SECONDS    604800
config::export ENROOT_TEMPLATE_PRESSURE_THRESHOLD 80
```

(Note: threshold is stored as integer percent, 0-100, to avoid bash floating-point. The 80 = 80%.)

- [ ] **Step 1.2: Document them in `conf/enroot.conf.in`**

After the `ENROOT_STORAGE_BACKEND` block from Plan A, add:

```
# How long (seconds) a ZFS template with no clones stays evictable only under
# disk pressure. 0 = evict immediately on remove (refcount-only). Default 7 days.
#ENROOT_TEMPLATE_WARM_SECONDS    604800

# Quota fraction (0-100) above which routine creates start evicting warm
# templates LRU until back under. Soft signal; the ZFS quota is the hard wall.
#ENROOT_TEMPLATE_PRESSURE_THRESHOLD 80
```

- [ ] **Step 1.3: Verify**

```sh
make
ENROOT_STORAGE_BACKEND=zfs ./enroot info | grep -E "WARM|PRESSURE"
```

Expected: both lines printed.

- [ ] **Step 1.4: Commit**

```sh
git add enroot.in conf/enroot.conf.in
git commit -s -m "Add ENROOT_TEMPLATE_WARM_SECONDS and PRESSURE_THRESHOLD knobs"
```

---

### Task 2: Track `enroot:last_used` on templates

**Files:**
- Modify: `src/storage_zfs.sh` — extend `zfs::ensure_template` and `zfs::clone_container`.

- [ ] **Step 2.1: Add a helper to update `last_used`**

Append to `src/storage_zfs.sh`:

```bash
# Updates the enroot:last_used user property on a template dataset to now.
zfs::touch_template() {
    local -r template="$1"
    zfs set "enroot:last_used=$(date +%s)" "${template}"
}
```

- [ ] **Step 2.2: Have `ensure_template` set `last_used` on extract**

In `src/storage_zfs.sh`, locate the block at the end of the "We won — extract" branch in `zfs::ensure_template`:

```bash
        zfs rename "${tmp}" "${template}"
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
        printf "%s" "${template}"
        return
```

Insert `zfs::touch_template "${template}"` just before `printf`:

```bash
        zfs rename "${tmp}" "${template}"
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
```

Also, in the fast-path branch (`if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then`), update the timestamp before printing:

```bash
    if zfs list -H -t snapshot "${snap}" > /dev/null 2>&1; then
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
    fi
```

- [ ] **Step 2.3: Verify timestamps land**

```sh
/tmp/enroot/usr/bin/enroot create -n t1 alpine.sqsh
zfs get enroot:last_used $(zfs list -H -o name -t filesystem | grep templates | head -1)
sleep 2
/tmp/enroot/usr/bin/enroot create -n t2 alpine.sqsh
zfs get enroot:last_used $(zfs list -H -o name -t filesystem | grep templates | head -1)
/tmp/enroot/usr/bin/enroot remove -f t1 t2
```

Expected: timestamp present after first create; updated (later value) after second create.

- [ ] **Step 2.4: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Track enroot:last_used on template extraction and reuse"
```

---

### Task 3: Decouple `destroy_container` from template destruction

Plan A's `zfs::destroy_container` reaped the template eagerly. Plan B leaves templates around for the warm period; eviction is the sweep's job, not remove's.

**Files:**
- Modify: `src/storage_zfs.sh:zfs::destroy_container`

- [ ] **Step 3.1: Strip the eager template-destroy from `destroy_container`**

In `src/storage_zfs.sh`, replace the `zfs::destroy_container` body with:

```bash
zfs::destroy_container() {
    local -r name="$1"
    local -r store=$(zfs::store_dataset)
    local -r target="${store}/${name}"

    if ! zfs list -H "${target}" > /dev/null 2>&1; then
        common::err "No such container: ${name}"
    fi

    zfs destroy "${target}"
    # Template lifecycle is owned by the eviction sweep — see zfs::sweep_templates.
}
```

- [ ] **Step 3.2: Verify remove no longer reaps the template**

```sh
/tmp/enroot/usr/bin/enroot create -n only alpine.sqsh
zfs list -H -o name -t filesystem | grep templates  # save count
/tmp/enroot/usr/bin/enroot remove -f only
zfs list -H -o name -t filesystem | grep templates
```

Expected: template still exists after remove.

- [ ] **Step 3.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Remove eager template destruction from destroy_container"
```

---

### Task 4: Add eviction-candidate enumeration

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 4.1: Add `zfs::eviction_candidates`**

Append to `src/storage_zfs.sh`:

```bash
# Prints a tab-separated list of evictable templates, sorted by enroot:last_used
# ascending (oldest first). Each line: "<dataset>\t<last_used_epoch>".
# A template is evictable iff it has @pristine and that snapshot has no clones.
zfs::eviction_candidates() {
    local -r store=$(zfs::store_dataset)
    local -r templates_dataset="${store}/${zfs_template_subdir}"

    # Bail fast if the templates dataset doesn't exist yet.
    zfs list -H "${templates_dataset}" > /dev/null 2>&1 || return 0

    # List all template datasets with their last_used and the snapshot's clones property.
    # Format: <name> <last_used> <clones-of-pristine>
    zfs list -H -r -d 1 -t filesystem -o name,enroot:last_used "${templates_dataset}" \
      | awk -v ds="${templates_dataset}" '$1 != ds && $1 != "-" { print $1"\t"$2 }' \
      | while IFS=$'\t' read -r ds ts; do
            local clones
            clones=$(zfs get -H -o value clones "${ds}@${zfs_pristine_snap}" 2> /dev/null) || continue
            if [ "${clones}" = "-" ] || [ -z "${clones}" ]; then
                # No clones — eligible.
                printf "%s\t%s\n" "${ds}" "${ts:--}"
            fi
        done \
      | sort -t $'\t' -k2,2n
}
```

- [ ] **Step 4.2: Verify enumeration**

```sh
/tmp/enroot/usr/bin/enroot create -n c1 alpine.sqsh
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         zfs::eviction_candidates'
# Expected: empty output (template has a clone, so not evictable).

/tmp/enroot/usr/bin/enroot remove -f c1
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         zfs::eviction_candidates'
# Expected: one line with the template dataset name and its timestamp.
```

- [ ] **Step 4.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::eviction_candidates enumeration"
```

---

### Task 5: Add pressure detection

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 5.1: Add `zfs::under_pressure`**

Append to `src/storage_zfs.sh`:

```bash
# Returns 0 if the templates dataset has a quota set and current usage is at or
# above ENROOT_TEMPLATE_PRESSURE_THRESHOLD percent. Returns 1 otherwise (no quota
# = no pressure check; under threshold = no pressure).
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
```

- [ ] **Step 5.2: Verify**

```sh
zfs set quota=200M tank/enroot/$USER/.templates
bash -c 'source ${ENROOT_LIBRARY_PATH}/common.sh
         source ${ENROOT_LIBRARY_PATH}/storage_zfs.sh
         zfs::under_pressure && echo "pressure" || echo "no pressure"'
```

Expected: depends on current usage. With a fresh test setup and one template, "no pressure". To force pressure, lower the quota: `zfs set quota=10M ...` then re-run; expect "pressure".

- [ ] **Step 5.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::under_pressure quota-fraction check"
```

---

### Task 6: Add eviction sweep

**Files:**
- Modify: `src/storage_zfs.sh` (append)

- [ ] **Step 6.1: Add `zfs::sweep_templates`**

Append to `src/storage_zfs.sh`:

```bash
# Sweeps evictable templates. Always reaps cold ones (last_used older than
# ENROOT_TEMPLATE_WARM_SECONDS); also reaps warm ones LRU when under pressure,
# stopping once back under threshold. With ENROOT_TEMPLATE_WARM_SECONDS=0 and
# no quota, this collapses to "reap any template with no clones".
zfs::sweep_templates() {
    local now warm_secs pressure
    now=$(date +%s)
    warm_secs="${ENROOT_TEMPLATE_WARM_SECONDS-604800}"
    zfs::under_pressure && pressure=y || pressure=

    zfs::eviction_candidates | while IFS=$'\t' read -r ds ts; do
        local age is_warm
        if [ "${ts}" = "-" ] || [ -z "${ts}" ]; then
            age=$((warm_secs + 1))   # missing timestamp = treat as cold
        else
            age=$(( now - ts ))
        fi

        if [ "${age}" -lt "${warm_secs}" ] && [ -z "${pressure}" ]; then
            continue                 # warm and no pressure: keep
        fi

        common::log INFO "Evicting template ${ds##*/} (age ${age}s)"
        zfs destroy "${ds}@${zfs_pristine_snap}" 2> /dev/null && \
            zfs destroy "${ds}" 2> /dev/null || :

        if [ -n "${pressure}" ]; then
            zfs::under_pressure || break    # back under — stop
        fi
    done
}
```

- [ ] **Step 6.2: Wire it into `zfs::ensure_template`**

In `src/storage_zfs.sh`, at the very top of `zfs::ensure_template`, before the fast-path snapshot check, add:

```bash
zfs::ensure_template() {
    local -r image="$1" sha="$2"
    local -r store=$(zfs::store_dataset)
    local -r template="${store}/${zfs_template_subdir}/${sha}"
    local -r tmp="${template}.tmp"
    local -r snap="${template}@${zfs_pristine_snap}"
    local mountpoint
    local i timeout=600

    zfs::sweep_templates

    # Fast path: ...
    ...
}
```

- [ ] **Step 6.3: Verify cold eviction**

```sh
export ENROOT_TEMPLATE_WARM_SECONDS=2
/tmp/enroot/usr/bin/enroot create -n a alpine.sqsh
/tmp/enroot/usr/bin/enroot remove -f a
sleep 3
zfs list -H -o name -t filesystem | grep templates    # should still exist
/tmp/enroot/usr/bin/enroot create -n b alpine.sqsh    # triggers sweep, then re-extracts
zfs list -H -o name -t filesystem | grep templates    # exists (the new one)
/tmp/enroot/usr/bin/enroot remove -f b
unset ENROOT_TEMPLATE_WARM_SECONDS
```

Expected: after the sleep, `create -n b` logs "Evicting template ..." for the old one before extracting fresh.

- [ ] **Step 6.4: Verify warm preservation**

```sh
export ENROOT_TEMPLATE_WARM_SECONDS=3600
/tmp/enroot/usr/bin/enroot create -n a alpine.sqsh
/tmp/enroot/usr/bin/enroot remove -f a
/tmp/enroot/usr/bin/enroot create -n b alpine.sqsh    # should be fast — clone, not extract
```

Expected: the second create should NOT log "Extracting squashfs filesystem" (template was warm and reused). Cleanup: `enroot remove -f b`.

- [ ] **Step 6.5: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add zfs::sweep_templates eviction with warm/cold/pressure logic"
```

---

### Task 7: ENOSPC retry path

**Files:**
- Modify: `src/storage_zfs.sh:zfs::ensure_template` (extraction block)

- [ ] **Step 7.1: Add a retry around the extraction**

In `zfs::ensure_template`, wrap the extraction in a retry that escalates eviction to all-warm on ENOSPC:

Replace this block:

```bash
        common::log INFO "Extracting squashfs filesystem into ZFS template..." NL
        [ $(ulimit -n) -gt $((2**26)) ] && ulimit -n $((2**26))
        unsquashfs ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
                   -user-xattrs -f -d "${mountpoint}" "${image}" >&2
        common::fixperms "${mountpoint}"
```

with:

```bash
        common::log INFO "Extracting squashfs filesystem into ZFS template..." NL
        [ $(ulimit -n) -gt $((2**26)) ] && ulimit -n $((2**26))
        if ! unsquashfs ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
                        -user-xattrs -f -d "${mountpoint}" "${image}" >&2; then
            # Could be ENOSPC or any other failure. Force a warm-aggressive sweep and retry once.
            common::log WARN "Extraction failed; evicting all warm templates and retrying"
            ENROOT_TEMPLATE_WARM_SECONDS=0 zfs::sweep_templates
            unsquashfs ${TTY_OFF+-no-progress} -processors "${ENROOT_MAX_PROCESSORS}" \
                       -user-xattrs -f -d "${mountpoint}" "${image}" >&2 \
              || common::err "Extraction failed even after evicting warm templates"
        fi
        common::fixperms "${mountpoint}"
```

- [ ] **Step 7.2: Verify retry under tight quota**

```sh
zfs set quota=10M tank/enroot/$USER/.templates    # too tight for alpine extraction (~5M)
/tmp/enroot/usr/bin/enroot create -n big1 alpine.sqsh
/tmp/enroot/usr/bin/enroot remove -f big1
zfs set quota=10M tank/enroot/$USER/.templates    # still tight; old template now warm
/tmp/enroot/usr/bin/enroot create -n big2 alpine.sqsh   # should log "Extraction failed; evicting all warm" and succeed
zfs set quota=200M tank/enroot/$USER/.templates    # restore
/tmp/enroot/usr/bin/enroot remove -f big2
```

Expected: second create succeeds after eviction; final state has only the new template.

- [ ] **Step 7.3: Commit**

```sh
git add src/storage_zfs.sh
git commit -s -m "Add ENOSPC retry with warm-aggressive sweep"
```

---

### Task 8: Document Plan B as implemented

**Files:**
- Modify: `doc/zfs.md`

- [ ] **Step 8.1: Update status note**

Update the status sentence near the top of `doc/zfs.md` to mention Plan B is now landed (the warm-period and pressure-eviction logic).

- [ ] **Step 8.2: End-to-end smoke**

```sh
export ENROOT_TEMPLATE_WARM_SECONDS=600
zfs set quota=200M tank/enroot/$USER/.templates
for i in 1 2 3; do
    /tmp/enroot/usr/bin/enroot create -n smoke_$i alpine.sqsh
    /tmp/enroot/usr/bin/enroot remove -f smoke_$i
done
zfs list -t all -r tank/enroot/$USER/.templates | head
# Expected: still one template (warm, reused across all three cycles).

ENROOT_TEMPLATE_WARM_SECONDS=0 /tmp/enroot/usr/bin/enroot create -n smoke_x alpine.sqsh
/tmp/enroot/usr/bin/enroot remove -f smoke_x
ENROOT_TEMPLATE_WARM_SECONDS=0 /tmp/enroot/usr/bin/enroot create -n smoke_y alpine.sqsh
zfs list -t all -r tank/enroot/$USER/.templates | wc -l
# Expected: just one again — old one was evicted by the WARM=0 sweep, replaced by new.
/tmp/enroot/usr/bin/enroot remove -f smoke_y
```

- [ ] **Step 8.3: Commit**

```sh
git add doc/zfs.md
git commit -s -m "Mark Plan B (template warm/cold lifecycle) as implemented"
```

---

## Self-review checklist

- [x] Spec coverage: warm-period (T2,T6), pressure threshold (T5,T6), routine cold sweep on every create (T6), ENOSPC retry (T7), `WARM_SECONDS=0` collapse to refcount-only (T6 — pressure-flag handling and warm_secs=0 means age >= warm_secs always, evict immediately).
- [x] Type consistency: `zfs::touch_template`, `zfs::eviction_candidates`, `zfs::under_pressure`, `zfs::sweep_templates` are defined in T2/T4/T5/T6 and only called from each other and `zfs::ensure_template`.
- [x] No placeholders.

## Execution Handoff

Same options as Plan A.
