# Implementation plans

Plans for landing the optional ZFS storage backend designed in [`../zfs.md`](../zfs.md). Each plan produces working, testable software on its own and is sized to be picked up independently.

| Plan | File | Depends on |
| ---- | ---- | ---------- |
| A. Foundation — `ENROOT_STORAGE_BACKEND=zfs`, clone-on-create, fast remove | [2026-04-29-zfs-a-foundation.md](2026-04-29-zfs-a-foundation.md) | — |
| B. Template warm/cold lifecycle — `ENROOT_TEMPLATE_WARM_SECONDS`, pressure-based eviction, ENOSPC retry | [2026-04-29-zfs-b-template-lifecycle.md](2026-04-29-zfs-b-template-lifecycle.md) | A |
| C. `.zfs` image format — `enroot create foo.zfs`, `enroot export --format=zfs` | [2026-04-29-zfs-c-zfs-format.md](2026-04-29-zfs-c-zfs-format.md) | A |
| D. `zfs://` URI transport — `enroot load zfs://host/NAME`, `enroot export NAME zfs://host` | [2026-04-29-zfs-d-zfs-uri.md](2026-04-29-zfs-d-zfs-uri.md) | A, C |
| E. Ephemeral start ZFS path — substitute `squashfuse + overlay` with throwaway clone | [2026-04-29-zfs-e-ephemeral-start.md](2026-04-29-zfs-e-ephemeral-start.md) | A |
| F. Docker layer-stack ZFS path — lift `ENROOT_NATIVE_OVERLAYFS=y` requirement on ZFS hosts | [2026-04-29-zfs-f-docker-load.md](2026-04-29-zfs-f-docker-load.md) | A |
| G. Per-layer ZFS clone chain (opt-in `ENROOT_ZFS_LAYER_CHAIN=y`) — cross-image layer dedup at the dataset level | [2026-05-01-zfs-g-layer-chain.md](2026-05-01-zfs-g-layer-chain.md) | F |

```
A ─┬─> B
   ├─> C ─> D
   ├─> E
   └─> F ─> G
```

Recommended landing order: **A → E → F → B → C → D → G**. A is the foundation; E/F give the most user-visible wins next; B improves cache economics; C/D add transport options; G is an opt-in optimization on top of F.

## Conventions used by these plans

- **No automated test suite.** Verification per task is a "run command X, expect Y" block. If the project gains a test framework (e.g., bats), retrofit the plans' verification blocks into proper tests.
- **DCO sign-off (`-s`) on every commit.** Required by `CONTRIBUTING.md`.
- **Frequent commits.** Each numbered task ends with a commit. Keeps blame and bisection useful.
- **Templates and ephemeral clones live under `.templates/` and `.ephemeral/` subdatasets** of `${ENROOT_DATA_PATH}`. They are dotfiles so `enroot list` does not show them.
- **All ZFS-specific helpers are in `src/storage_zfs.sh`** under the `zfs::` namespace. Other modules import behavior via `zfs::enabled` predicates and named helpers; they should not call `zfs(8)` directly.
