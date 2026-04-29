# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Enroot is an unprivileged container runtime — an "enhanced unprivileged `chroot(1)`" that imports Docker/OCI images and runs them inside user/mount namespaces with little-to-no isolation overhead. It is a CLI-only tool (no daemon), targeted at HPC and multi-user systems. The user-facing surface is the `enroot` bash script plus a handful of small static C helpers.

## Build / develop

The project uses a plain `Makefile` (no autotools, no test suite). Several pieces are non-obvious:

- **Submodules are mandatory.** `make` invokes `git submodule update --init` to pull `deps/musl`, `deps/libbsd`, `deps/linux-headers`, `deps/makeself`. A fresh clone without `--recurse-submodules` will not build until you run `make deps` (or any `make` target — `deps` is a prerequisite).
- **Helper C binaries (`bin/enroot-*`) link statically against musl**, not the system glibc. The Makefile rewrites `CC` to `deps/dist/musl/bin/musl-gcc` (or `musl-clang`) for those targets and adds `-static-pie`. To build with the system toolchain instead, set `FORCE_GLIBC=1`.
- **`enroot.in` and `conf/enroot.conf.in` are templated** with `sed` at build time — `@sysconfdir@`, `@libdir@`, `@version@` are substituted from Makefile variables. Never edit the generated `enroot` / `conf/enroot.conf` files; edit the `.in` versions.

Common targets:

```sh
make                # build enroot script, conf, deps, helper utils
make deps           # build submodules into deps/dist/ only
make depsclean      # clean submodule build artifacts
make mostlyclean    # remove generated enroot, conf, utils (keeps deps)
make clean          # mostlyclean + depsclean
make install        # install to $(DESTDIR)$(prefix), default /usr/local
make setcap         # grant CAP_SYS_ADMIN/CAP_MKNOD to mksquashovlfs/aufs2ovlfs
make dist           # build and tar a relocatable installation
make deb            # build .deb via debuild (uses pkg/deb/)
make rpm            # build .rpm via rpmbuild (uses pkg/rpm/)
make release        # full multi-arch release via pkg/release/ docker scripts
DEBUG=1 make        # build helpers with ASan/UBSan/leak sanitizers and -g3
```

Cross-compilation: set `CROSS_COMPILE=<triple>-` (e.g. `aarch64-linux-gnu-`); the Makefile derives `CC` and the host triple from it.

There are **no automated tests**. Verification is manual: `make install` into a prefix and exercise `enroot import`/`create`/`start`. CI is limited to LGTM (`.lgtm.yml`) for static analysis on `deps/**/*.c`.

## Architecture

The runtime is a bash front-end plus a few small privileged-helper C binaries.

**Top-level entry point: `enroot.in`** — single bash script (templated to `enroot`). It loads `enroot.conf`, exports `ENROOT_*` paths, then `source`s the libraries and dispatches subcommands (`import`, `create`, `start`, `bundle`, `export`, `list`, `remove`, `exec`, `batch`, `load`, `digest`, `info`, `version`). Subcommand handlers (`enroot::import`, `enroot::start`, …) live in this file and call into the libraries.

**Library modules in `src/` (sourced, not executed):**
- `common.sh` — logging, error formatting, `curl` wrapper, `runparts`, env/fstab parsing, locking helpers. Sourced by all others.
- `runtime.sh` — container lifecycle: assembling environ/fstab, running pre-start hooks, invoking `enroot-mount` and `enroot-switchroot`, managing rootfs in `ENROOT_DATA_PATH`.
- `docker.sh` — Docker Registry v2 client (auth tokens, manifest/blob fetching, image extraction). Pure bash + `curl` + `jq`.
- `bundle.sh` — generates self-extracting `.run` bundles via `enroot-makeself` (a vendored fork of makeself).

**C helpers in `bin/` (each is a single-file program):**
- `enroot-mount` — reads an fstab and performs mounts (supports the enroot extensions: `x-create=`, `x-move`, `x-detach`, env-var substitution, `fs_passno` as ordering key).
- `enroot-switchroot` — pivots into the rootfs and execs `/etc/rc`.
- `enroot-nsenter` — joins existing namespaces (used by `enroot exec`).
- `enroot-aufs2ovlfs` / `enroot-mksquashovlfs` — flatten a layered Docker overlay into a single rootfs / squashfs. These need `CAP_SYS_ADMIN` (and `CAP_MKNOD` for aufs2ovlfs) — granted by `make setcap` or by installing the `enroot+caps` package.

**Configuration (`conf/`)** is split into three layered drop-in directories, each loaded from both `ENROOT_SYSCONF_PATH` (system-wide, default `/etc/enroot`) and `ENROOT_CONFIG_PATH` (per-user, default `~/.config/enroot`):
- `hooks.d/*.sh` — pre-start bash hooks run with full host capabilities before pivot. Numeric prefix controls order. `extra/` hooks ship to `$datadir/enroot/hooks.d` and are opt-in (admin symlinks them in).
- `mounts.d/*.fstab` — additional fstab entries merged with the image's `/etc/fstab`.
- `environ.d/*.env` — additional env vars merged with the image's `/etc/environment`.

When debugging container behavior, the order is: image `/etc/{rc,fstab,environment}` → sysconf drop-ins → user config drop-ins → CLI flags (`-e`, `-m`, `-c`, `--rc`).

**Container image format:** plain squashfs. The runtime treats three files inside the rootfs specially: `/etc/rc` (entrypoint), `/etc/fstab` (mounts, with enroot extensions), `/etc/environment` (env vars). See `doc/image-format.md`.

**Filesystem layout at runtime:**
- `ENROOT_DATA_PATH` (`~/.local/share/enroot`) — extracted container rootfs trees, one per name.
- `ENROOT_CACHE_PATH` (`~/.cache/enroot`) — registry credentials, layer cache, auth tokens (per-EUID subdir).
- `ENROOT_RUNTIME_PATH` (`/run/enroot`) — per-container ephemeral state (assembled fstab, environ, rc, lock).

## Active design proposals

- **`doc/zfs.md`** — optional ZFS storage backend (`ENROOT_STORAGE_BACKEND=zfs`). Replaces `unsquashfs`-per-create with extract-once-then-`zfs clone`. Adds a `.zfs` (zfs send stream) image format and a `zfs://host/NAME` transport scheme alongside today's `.sqsh`. Introduces a shared template cache with a live/warm/cold lifecycle (knobs: `ENROOT_TEMPLATE_WARM_SECONDS`, `ENROOT_TEMPLATE_PRESSURE_THRESHOLD`; eviction is implicit on `create`, no daemon, no `enroot gc` command). Default backend (`dir`) is unchanged.
- **`doc/plans/`** — six implementation plans (A–F) breaking the ZFS backend into independently-landable slices. Start with `doc/plans/README.md` for the index and recommended landing order (A → E → F → B → C → D). Plans add a new sourced module `src/storage_zfs.sh` (under a `zfs::` namespace) and branch in `src/runtime.sh`, `src/docker.sh` on `ENROOT_STORAGE_BACKEND`. **Plans A, E, F, B merged; C in review** on `zenroot/main` (PRs [zeroae/enroot#1](https://github.com/zeroae/enroot/pull/1), [#2](https://github.com/zeroae/enroot/pull/2), [#3](https://github.com/zeroae/enroot/pull/3), [#5](https://github.com/zeroae/enroot/pull/5), [#7](https://github.com/zeroae/enroot/pull/7)); D is still design-only.

## Conventions

- All bash files use `set -euo pipefail; shopt -s lastpipe` and require **bash >= 4.2**.
- Functions are namespaced with `::` (`common::log`, `runtime::start`, `docker::pull`, `enroot::import`).
- C helpers are intentionally minimal, statically linked, and use `err()`/`errx()` from libbsd. Compiled with the strict `-Wall -Wextra -Wcast-align -Wconversion -Wsign-conversion -Werror`-adjacent flag set in the Makefile — match this style for any new C.
- `conf/hooks/*.sh` numeric prefix encodes phase; keep new hooks consistent (10-* runs first, 99-* last; 50-* is reserved for opt-in `extra/`).

## Contributing

Every commit must be DCO-signed (`git commit -s`). See `CONTRIBUTING.md`. There is no separate code-style or PR-template doc.

## Fork workflow (zeroae/enroot)

This working copy is a fork. Changes are **not destined for upstream merge** — `nvidia/enroot` is treated as a read-only source we periodically absorb from. The fork lives at `https://github.com/zeroae/enroot`.

**Remotes:**
- `origin` → `https://github.com/zeroae/enroot.git` — the fork; push here.
- `upstream` → `https://github.com/nvidia/enroot.git` — read-only; never push.

**Branches:**
- `main` — local mirror of `upstream/main`. Never commit here directly. Refresh with `git fetch upstream && git push origin upstream/main:main`.
- `zenroot/main` — the **fork's default branch** and integration line. All feature work lands here. Periodically rebased onto `upstream/main` (see below).
- `feature/<name>` — branch off `zenroot/main`, PR back into `zenroot/main`. **Branches are kept after merge** (not deleted) so the per-plan history stays browsable on GitHub. Use the merge commit on `zenroot/main` as the canonical reference; the `feature/<name>` branch ref is a frozen pointer to the pre-merge state.

**Opening a PR** (after pushing the feature branch):
```sh
gh pr create --base zenroot/main --head feature/<name> --title "..." --body "..."
```
`zenroot/main` is the fork's default branch, so `--base` can usually be omitted, but state it explicitly to guard against accidental upstream targeting.

**Absorbing upstream changes** — do this from `zenroot/main`, never on a live feature branch:
```sh
git checkout zenroot/main
git fetch upstream
git rebase upstream/main             # resolve conflicts here once
git push --force-with-lease origin zenroot/main
```
Force-push is acceptable on `zenroot/main` because it's the integration branch. **Never force-push** a `feature/*` branch once it's under review; rebase only before opening the PR. If a feature branch needs to absorb the latest `zenroot/main` mid-review, prefer a merge commit over a rebase.

**Plan stack:** the six plans in `doc/plans/` each map to one PR into `zenroot/main`. Recommended order is `A → E → F → B → C → D`; B/C/D/E/F all depend on A. After each plan merges, branch the next one from the freshly-merged `zenroot/main`.
