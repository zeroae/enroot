# ZFS Template Metadata + Unmount-When-Idle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tag template datasets with their docker provenance (`enroot:uri`, `enroot:manifest-digest`, `enroot:arch`, `enroot:imported`) and unmount idle templates so the only mountpoints visible at rest are active container clones.

**Architecture:** Two surgical changes to `src/storage_zfs.sh`. (1) After each of the three template-install paths sets `readonly=on`, set the universal `enroot:imported` property and unmount the template. (2) Add a `zfs::set_template_metadata` helper called by the docker-aware import paths to attach `enroot:uri` / `enroot:manifest-digest` / `enroot:arch`. Add a one-liner inspection recipe to `doc/zfs.md`.

**Tech Stack:** Bash, OpenZFS user properties (already in use via `enroot:last_used`), the existing `enroot-zfs-mount --unmount` helper.

**Spec:** [docs/superpowers/specs/2026-05-01-zfs-template-props-and-unmount-design.md](../specs/2026-05-01-zfs-template-props-and-unmount-design.md).

**Branch:** `feature/zfs-template-props` (already created, spec committed there).

---

## File Structure

| File | Responsibility |
|---|---|
| `src/storage_zfs.sh` | New `zfs::set_template_metadata` helper. Three template-install functions (`_install_template_from_layers`, `ensure_template`, `ensure_template_from_stream`) gain a 2-line tail: set `enroot:imported`, unmount template. Two callers (`import_docker_pointer`, `create_from_pointer` recovery path) call `set_template_metadata` after install. |
| `doc/zfs.md` | One-paragraph "Inspecting cached templates" subsection with a `zfs list` one-liner. |

No new files. No CLI changes. No version bump in this PR (refinement; ships with whatever zfs.5 picks up next).

---

## Task 1: Add `zfs::set_template_metadata` helper

**Why:** Centralize the property-setting logic so callers don't repeat themselves and the property names stay in one place.

**Files:**
- Modify: `src/storage_zfs.sh`. Insert a new function near the top, between `zfs::touch_template` (line ~51) and `zfs::template_exists` (line ~55) — these are all template-metadata helpers and belong together.

- [ ] **Step 1: Locate the insertion point**

```bash
grep -n "^zfs::touch_template\|^zfs::template_exists" src/storage_zfs.sh
```

Expected: `zfs::touch_template` at line 48, `zfs::template_exists` at line 55. Insert the new function between line 51 (closing `}` of `touch_template`) and line 53 (the comment block above `template_exists`).

- [ ] **Step 2: Insert the helper**

After the closing `}` of `zfs::touch_template`, insert (preserving the surrounding blank lines):

```bash

# Stamps a template dataset with docker provenance properties so the
# dataset is self-describing even after its (transient) pointer file is
# gone. Always called from a context where the inputs have already been
# regex-validated (write_pointer / read_pointer in zfs.4 — the callers
# pass values that survived those regex gates), so we don't re-validate
# here. Best-effort: any property set that fails (e.g. delegation
# missing on an upgraded cluster) logs nothing — the template still
# functions; only the operator-visible metadata is degraded.
zfs::set_template_metadata() {
    local -r template="$1" uri="$2" manifest_digest="$3" arch="$4"
    zfs set "enroot:uri=${uri}" "${template}" 2> /dev/null || :
    zfs set "enroot:manifest-digest=${manifest_digest}" "${template}" 2> /dev/null || :
    zfs set "enroot:arch=${arch}" "${template}" 2> /dev/null || :
}
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

Expected: silent.

- [ ] **Step 4: Commit (DCO-signed)**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: add zfs::set_template_metadata helper

Centralizes the per-template docker-provenance property-set
(enroot:uri, enroot:manifest-digest, enroot:arch). Best-effort: a
failed property-set leaves the template fully functional, only the
operator-visible metadata is degraded.

No callers yet — wired in by later tasks."
```

---

## Task 2: Stamp `enroot:imported` and unmount in the three template-install paths

**Why:** Every template, whatever its origin, should be self-describing about *when* it was installed and should sit at zero mountpoints when idle.

**Files:**
- Modify: `src/storage_zfs.sh` — three functions:
  - `zfs::_install_template_from_layers` (the merge path used by docker imports)
  - `zfs::ensure_template` (the legacy `.sqsh`-extraction path)
  - `zfs::ensure_template_from_stream` (the `zfs://` receive path)

Each function has the same tail-of-install code shape:

```bash
zfs snapshot "${snap}"
# zfs set readonly=on or related; existing
zfs::touch_template "${template}"
```

We're adding two new lines after `zfs set readonly=on` (or equivalent) and before `zfs::touch_template`:

```bash
zfs set "enroot:imported=$(date -u +%FT%TZ)" "${template}" 2> /dev/null || :
enroot-zfs-mount --unmount "${template}" 2> /dev/null || :
```

- [ ] **Step 1: Find each install path's tail**

```bash
grep -n "zfs set readonly=on" src/storage_zfs.sh
```

Expected: three matches (one per function).

- [ ] **Step 2: Patch `zfs::_install_template_from_layers`**

In the function body, find:

```bash
        zfs snapshot "${snap}"
        # `zfs set readonly=on` triggers an implicit remount that needs
        # CAP_SYS_ADMIN; for unprivileged callers the property is set but
        # the remount fails and zfs(8) exits non-zero. Suppress both the
        # warning and the non-zero exit — what we actually care about
        # (the property bit) is set regardless of the remount.
        zfs set readonly=on "${template}" 2> /dev/null || :
        zfs::touch_template "${template}"
```

and replace the last two lines with:

```bash
        zfs set readonly=on "${template}" 2> /dev/null || :
        zfs set "enroot:imported=$(date -u +%FT%TZ)" "${template}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${template}" 2> /dev/null || :
        zfs::touch_template "${template}"
```

(The order matters: `readonly=on` first so the imported timestamp gets set on a read-only dataset; user properties bypass `readonly` so the timestamp set still succeeds. Then unmount, then `touch_template` which is a property set so it doesn't need the dataset mounted.)

- [ ] **Step 3: Patch `zfs::ensure_template`**

Find the corresponding tail (around the `printf "%s" "${template}"` and the preceding `zfs::touch_template "${template}"`):

```bash
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}"
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
```

Replace with:

```bash
        zfs snapshot "${snap}"
        zfs set readonly=on "${template}" 2> /dev/null || :
        zfs set "enroot:imported=$(date -u +%FT%TZ)" "${template}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${template}" 2> /dev/null || :
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
```

(Note: this is also a good time to apply the same `2>/dev/null || :` to `zfs set readonly=on` in this function — the same partial-success-with-non-zero-exit issue applies. Was previously fixed only in `_install_template_from_layers` because the cluster smoke test only exercised that path.)

- [ ] **Step 4: Patch `zfs::ensure_template_from_stream`**

Find the corresponding tail:

```bash
        zfs set readonly=on "${template}"
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
```

Replace with:

```bash
        zfs set readonly=on "${template}" 2> /dev/null || :
        zfs set "enroot:imported=$(date -u +%FT%TZ)" "${template}" 2> /dev/null || :
        enroot-zfs-mount --unmount "${template}" 2> /dev/null || :
        zfs::touch_template "${template}"
        printf "%s" "${template}"
        return
```

- [ ] **Step 5: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

Expected: silent.

- [ ] **Step 6: Verify the three patches via grep**

```bash
grep -B1 -A1 'enroot:imported=' src/storage_zfs.sh
```

Expected: three occurrences, each preceded by `zfs set readonly=on` and followed by `enroot-zfs-mount --unmount`.

- [ ] **Step 7: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: stamp enroot:imported and unmount idle templates

Every freshly-installed template gets enroot:imported (RFC3339 UTC) and
is unmounted before the function returns. zfs clone <template>@pristine
does not require the source to be mounted, so idle templates can sit at
zero mountpoints — only active container clones (and the .templates /
.ephemeral parents) remain visible in mount(8) output.

Applies to all three template-install paths: docker layer-merge,
.sqsh extraction, and .zfs send-stream receive. Also harmonizes the
zfs.4 readonly=on || : fix across all three paths (was previously only
in the docker-merge path)."
```

---

## Task 3: Wire `set_template_metadata` into the docker-aware paths

**Why:** Templates born of docker imports also know their docker URI / manifest digest / arch. Stamping these turns a dataset like `tank/enroot/data/.templates/3c2204…` into something whose `zfs get all` tells the operator "this is `docker://ubuntu:24.04` from 2026-05-01."

**Files:**
- Modify: `src/storage_zfs.sh` — `zfs::import_docker_pointer` and `zfs::create_from_pointer`'s eviction-recovery path.

- [ ] **Step 1: Patch `zfs::import_docker_pointer`**

Find the tail of the function:

```bash
    config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}")

    zfs::write_pointer "${output_path}" "${config_sha}" "${manifest_digest}" "${arch}" "${uri}"
```

Replace with:

```bash
    config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}")

    local store
    store=$(zfs::store_dataset)
    zfs::set_template_metadata "${store}/${zfs_template_subdir}/${config_sha}" \
        "${uri}" "${manifest_digest}" "${arch}"

    zfs::write_pointer "${output_path}" "${config_sha}" "${manifest_digest}" "${arch}" "${uri}"
```

- [ ] **Step 2: Patch `zfs::create_from_pointer`'s recovery path**

Find the eviction-recovery block:

```bash
    fresh_config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}")
    if [ "${fresh_config_sha}" != "${image_config_sha256}" ]; then
        common::err "Pointer ${pointer_path} references image-config-sha256 ${image_config_sha256:0:12}, but ${uri} now resolves to ${fresh_config_sha:0:12}. Delete and re-import."
    fi

    store=$(zfs::store_dataset)
    template="${store}/${zfs_template_subdir}/${image_config_sha256}"
    zfs::clone_container "${template}" "${name}"
```

Insert the metadata stamp between the mismatch check and the clone:

```bash
    fresh_config_sha=$(zfs::_pull_and_install_template "${uri}" "${arch}")
    if [ "${fresh_config_sha}" != "${image_config_sha256}" ]; then
        common::err "Pointer ${pointer_path} references image-config-sha256 ${image_config_sha256:0:12}, but ${uri} now resolves to ${fresh_config_sha:0:12}. Delete and re-import."
    fi

    store=$(zfs::store_dataset)
    template="${store}/${zfs_template_subdir}/${image_config_sha256}"
    zfs::set_template_metadata "${template}" "${uri}" "${manifest_digest}" "${arch}"
    zfs::clone_container "${template}" "${name}"
```

- [ ] **Step 3: Syntax-check**

```bash
bash -n src/storage_zfs.sh
```

- [ ] **Step 4: Verify wiring via grep**

```bash
grep -n "zfs::set_template_metadata" src/storage_zfs.sh
```

Expected: 3 matches — one definition (Task 1) plus two call sites (`import_docker_pointer` and `create_from_pointer`).

- [ ] **Step 5: Commit**

```bash
git add src/storage_zfs.sh
git commit -s -m "storage_zfs: stamp docker provenance on imported templates

import_docker_pointer and the eviction-recovery path of
create_from_pointer now stamp enroot:uri, enroot:manifest-digest, and
enroot:arch on the freshly-installed template. Templates created by
docker imports become self-describing — operators can run
\`zfs get -r enroot:uri tank/enroot/data/.templates\` to see which
docker image each cached template came from, even after the (transient)
pointer file has been deleted."
```

---

## Task 4: Add the inspection recipe to `doc/zfs.md`

**Why:** Operators need to know the user properties exist and how to read them.

**Files:**
- Modify: `doc/zfs.md`. Add a new subsection under the existing `## Pointer-format import (default on ZFS backend)` section (or somewhere near the cache-lifecycle docs — judge by the file's existing structure).

- [ ] **Step 1: Locate a good insertion point**

```bash
grep -n "^##\|^###" doc/zfs.md | head -30
```

Find the section that documents the template cache or eviction lifecycle. The new subsection `### Inspecting cached templates` belongs near it.

- [ ] **Step 2: Insert the subsection**

```markdown
### Inspecting cached templates

Each template dataset carries ZFS user properties recording when it was imported and (for docker-sourced templates) where it came from:

| Property | Set on | Meaning |
|---|---|---|
| `enroot:imported` | every template | RFC3339 UTC timestamp of install |
| `enroot:last_used` | every template, refreshed on each clone | epoch seconds, drives the warm/cold sweep |
| `enroot:uri` | docker-sourced templates | the `docker://...` URI it was pulled from |
| `enroot:manifest-digest` | docker-sourced templates | registry manifest digest at import time |
| `enroot:arch` | docker-sourced templates | debian arch (`arm64`, `amd64`, `ppc64le`) |

A one-liner to see what's cached:

```sh
zfs list -o name,enroot:uri,enroot:imported,enroot:last_used,used \
         -r -d 1 ${POOL}/.templates
```

Properties are replicated by `zfs send -p`, so `enroot:uri` and friends survive the existing `zfs://<host>/<name>` SSH transport — a template pulled to one node carries its provenance to its peers.

Idle templates are unmounted (zero mountpoints under `${ENROOT_DATA_PATH}/.templates`); only active container clones appear in `mount(8)` output. The dataset and its `@pristine` snapshot remain — `zfs clone` does not require the source to be mounted.
```

(Replace `${POOL}` with the placeholder convention already in use elsewhere in the file. Read `doc/zfs.md` to match the surrounding style.)

- [ ] **Step 3: Verify the markdown**

```bash
# Code fences should balance:
grep -c '^```' doc/zfs.md
```

Expected: even number.

- [ ] **Step 4: Commit**

```bash
git add doc/zfs.md
git commit -s -m "doc: zfs.md inspection recipe for template metadata

Documents the enroot:* user properties carried by each template and a
canonical zfs list one-liner for operator inspection. Notes that
properties replicate via zfs send -p (so they survive the zfs:// SSH
transport) and that idle templates are unmounted."
```

---

## Task 5: Smoke-test (optional, manual, on a ZFS-backed node)

The project has no automated tests. Verification is by hand:

- [ ] **Step 1: Build .deb on the dev box, install on a compute node**

Per the existing CLAUDE.md "Smoke-test cluster" section.

- [ ] **Step 2: Fresh-import test**

```bash
sudo zfs destroy -r ${POOL}/.templates/<expected-config-sha> 2>/dev/null || :
rm -f /tmp/u.sqsh
enroot import -o /tmp/u.sqsh docker://ubuntu:24.04
zfs get -H -o property,value enroot:uri,enroot:manifest-digest,enroot:arch,enroot:imported \
    ${POOL}/.templates/<config-sha>
mount | grep "${POOL}/.templates" || echo "OK: no template mountpoints"
```

Expected: all four properties set; no mountpoints under `.templates/<sha>`.

- [ ] **Step 3: Pointer-create still works**

```bash
enroot remove -f t1 2>/dev/null
time enroot create -n t1 /tmp/u.sqsh
enroot start t1 cat /etc/os-release | head -1
enroot remove -f t1
```

Expected: subseconds; container starts; container clone DOES appear in `mount` output.

- [ ] **Step 4: zfs send -p preserves properties**

```bash
zfs send -p ${POOL}/.templates/<sha>@pristine | zfs receive ${POOL}/test-recv
zfs get enroot:uri ${POOL}/test-recv
zfs destroy -r ${POOL}/test-recv
```

Expected: the receive-side dataset has the same `enroot:uri` value.

---

## Self-Review Checklist

1. **Spec coverage:** All §3 (Approach) items have tasks. §3.1 → Tasks 1 + 3. §3.2 → Task 2. §3.3 → Task 4. §4 (set_template_metadata signature) → Task 1.
2. **Identifier consistency:** `zfs::set_template_metadata` named identically across spec, plan, and tasks. `enroot:imported`, `enroot:uri`, `enroot:manifest-digest`, `enroot:arch` named identically across tasks 1, 2, 3, 4.
3. **Function-tail consistency:** Task 2 applies the same 2-line append (set imported + unmount) to all three install functions; the order (`readonly=on` → `imported` → `unmount` → `touch_template`) is identical across all three.
4. **No placeholders:** every code block is complete; no "TBD" / "TODO" / "fill in details."
