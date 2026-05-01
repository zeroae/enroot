# ZFS template metadata properties + unmount-when-idle design

**Goal:** Two small, paired refinements to the ZFS backend that turn opaque, always-mounted template datasets into self-describing, on-demand-only datasets.

**Status:** Approved-by-conversation 2026-05-01. Ready for implementation plan.

## 1. Problem

After today's pyxis re-test session two operator pain-points surfaced:

1. **Templates are opaque.** Each cached template is a sha256 named directory under `/var/lib/enroot/.templates/`. Nothing about the dataset itself tells you which docker image it came from, when it was imported, or which arch it was pulled for. The pointer file (zfs.4) carries that metadata but is transient (pyxis `unlink`s it after `enroot create`); once the pointer is gone, the dataset is just an opaque hash.
2. **Templates clutter `mount(8)` / `df` output.** Every cached template is mounted at `/var/lib/enroot/.templates/<sha>` for the lifetime of the template, even though templates are read-only and `zfs clone` does NOT require the source to be mounted. With many cached images the noise is real and obscures the active-container mounts you actually care about.

## 2. Goal

Templates carry their own provenance (docker URI, manifest digest, arch, import timestamp) as ZFS user properties — readable via `zfs get` whether mounted or not, replicated by `zfs send -p`, validated as shell-safe under the regexes added in zfs.4. Idle templates are unmounted; only the in-use container clones (and the `.templates` / `.ephemeral` parents) appear in `mount(8)` output.

## 3. Approach

### 3.1 User properties on templates

In each of the three template-install paths (`_install_template_from_layers`, `ensure_template` for `.sqsh` extraction, `ensure_template_from_stream` for `zfs://` receive), set the following ZFS user properties on the freshly-installed template:

| Property | Value | Source |
|---|---|---|
| `enroot:uri` | `docker://...` | docker import path only — passed in from caller |
| `enroot:manifest-digest` | `sha256:<64-hex>` | docker import path only — passed in from caller |
| `enroot:arch` | `arm64` / `amd64` / `ppc64le` | docker import path only — passed in from caller |
| `enroot:imported` | RFC3339 UTC | always — `date -u +%FT%TZ` at install time |
| `enroot:last_used` | epoch seconds | already set by `zfs::touch_template` (unchanged) |

The `.sqsh` and `.zfs` template paths populate `enroot:imported` only — they don't have docker provenance. (Operators using `zfs://` transport with `zfs send -p` will inherit whatever properties were on the source template, which preserves the docker provenance across nodes — a nice property at zero cost.)

`enroot:image-config-sha256` is intentionally NOT added — it's the dataset's own name. Redundant.

### 3.2 Unmount templates after install

In each of the three template-install paths, after `zfs set readonly=on`, call `enroot-zfs-mount --unmount "${template}"`. Templates become zero-mountpoint while idle. `zfs clone <template>@pristine <target>` does not require the source to be mounted, so `zfs::clone_container` and `zfs::ephemeral_clone` are unaffected. `zfs::sweep_templates` already does `enroot-zfs-mount --unmount` before `zfs destroy` (with `|| :`) — that becomes a no-op when the template is already unmounted, harmless.

The hit path in each install function (`zfs list -t snapshot ${snap}` succeeds → `zfs::touch_template` → return) already does NOT re-mount the template. Already correct.

### 3.3 Documentation

`doc/zfs.md` gains a one-liner showing operators how to inspect cached templates:

```sh
zfs list -o name,enroot:uri,enroot:imported,enroot:last_used,used \
         -r -d 1 tank/enroot/data/.templates
```

No new `enroot info-templates` subcommand. Operators already have ZFS tooling.

## 4. Function-signature changes

`zfs::_install_template_from_layers` currently takes `(cache_key, layer_count, unpriv)`. To set the docker properties without forcing internal helpers to know about them, **callers** set the properties after install returns — keeps the install function focused on filesystem mechanics. New helper:

```bash
zfs::set_template_metadata <template> <uri> <manifest_digest> <arch>
```

Called by `zfs::import_docker_pointer` and `zfs::_pull_and_install_template`'s recovery flow. Sets `enroot:uri`, `enroot:manifest-digest`, `enroot:arch`. (`enroot:imported` is set inside the install function itself since it's universal.) Idempotent — calling on an already-tagged template re-sets the properties (harmless, lets recovery refresh stale metadata).

`zfs::ensure_template` (`.sqsh` path) and `zfs::ensure_template_from_stream` (`.zfs` path) don't have docker provenance — they only set `enroot:imported`.

## 5. Files affected

| File | Change |
|---|---|
| `src/storage_zfs.sh` | New `zfs::set_template_metadata`. `_install_template_from_layers`, `ensure_template`, `ensure_template_from_stream` set `enroot:imported` and unmount-after-install. `import_docker_pointer` and the eviction-recovery path in `create_from_pointer` call `set_template_metadata` after install returns. |
| `doc/zfs.md` | Add inspection one-liner. |

No CLI changes. No `Makefile` / version bump (the spec is approved-by-conversation as a refinement; ship in the next zfs.5 release line whenever that lands).

## 6. Trust / security

User properties are validated by the regexes already in place in `zfs::write_pointer` / `zfs::read_pointer` (zfs.4). The `set_template_metadata` callers always source these from already-validated values:
- The pointer-import path validates inputs before reaching `set_template_metadata`.
- The eviction-recovery path uses values read from a pointer file (already validated by `read_pointer`).

`zfs allow` already covers `userprop` (added in zfs.3). No additional delegation needed.

## 7. Out of scope

- New `enroot info` subcommand (operator can `zfs list -o ...` directly).
- Backfilling properties on already-cached templates from prior versions (will get backfilled on next `enroot create` of that image, which re-runs install with the new code).
- Changes to `dir` backend.
- Surfacing properties in `enroot list` output.

## 8. Acceptance

- `zfs list -o name,enroot:uri,enroot:imported tank/enroot/data/.templates` shows the URI/timestamp for templates created by docker imports.
- Templates created by docker imports have `enroot:uri`, `enroot:manifest-digest`, `enroot:arch`, `enroot:imported`, `enroot:last_used` all set.
- `mount | grep enroot` shows only active container clones plus the `.templates` / `.ephemeral` parents — no per-template mounts for idle templates.
- `zfs send -p` of a template includes `enroot:*` properties in the stream; `zfs receive` reconstitutes them.
- Existing pyxis end-to-end smoke test still passes.
