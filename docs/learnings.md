# Why the rules are the way they are

Arin's rules come from hands-on cleanups of developer Macs that run coding agents across many parallel worktrees. This file records what those cleanups showed, so rule changes can be checked against evidence.

## Where the space usually goes

| Source | Commonly seen | Notes |
|---|---:|---|
| Go build cache (`~/Library/Caches/go-build`) | 5–20+ GB | Can grow by tens of GB in a day when agents build and test many worktrees in parallel. Go only trims entries unused for ~5 days and has no size cap. |
| Per-run Go caches in `$TMPDIR` and `/tmp` | 3–18 GB | One-off `GOCACHE` folders that tools and agents create for a single build or lint run. |
| Xcode DerivedData, including copies in `$TMPDIR` | 2–25 GB | Scripted builds (perf or screenshot runs) often keep their own multi-GB copy. |
| Simulator device data | 5–25 GB | Includes devices left unavailable after runtime upgrades. |
| Duplicate or beta simulator runtimes | 8–18 GB each | A beta runtime next to the release build of the same version. |
| Git worktrees | 5–25 GB merged and clean | Hundreds of linked worktrees accumulate. Most of the size is repeated `bin/`, `.build`, and `node_modules`. |
| Repo-root `bin/` folders | Up to tens of GB | Envtest `bin/k8s` copied into every worktree, linters, controller-gen, Python test environments. |
| `node_modules` / Swift `.build` | 5–15 GB each | Repeated in every worktree. |
| Package caches | 10–20 GB | uv, pnpm, Homebrew, bun, npm, trivy, golangci-lint, SwiftPM, Yarn. |
| Old tool releases | 3–4 GB | Old Codex releases, old Claude Code and Copilot versions, unused Rust toolchains. |
| Agent data | 15–55 GB | Codex sessions, a log database that is mostly free pages, review and validation folders. |

## Rules that came from mistakes

1. **Measure free space, not folder sizes.** `du` counts APFS clones and shared blocks in full. Deleting 12 GB of session files has freed under 5 GB; removing unavailable simulators can free almost nothing; code-signing clones can report tens of GB that is mostly shared. Arin reports the measured change in free space and explains any gap.
2. **Snapshots hold deleted files.** A staged macOS update creates `com.apple.os.update-*` and `MSUPrepareUpdate` snapshots, and gains stop showing up. Never delete Preboot, `/System/Library/AssetsV2`, or update snapshots by hand. Finish the update and restart instead.
3. **Read-only trees break `rm`.** Go module caches and envtest binaries are read-only, which breaks worktree removal and deleting `bin/`, `.build`, and worktrunk trash. Arin retries once after `chmod -R u+w`.
4. **Native cleanup commands don't always work:**
   - `pnpm store prune` frees nothing while deleted projects are still registered.
   - `bun pm cache rm` refuses to run outside a project.

   Arin deletes those two stores directly. For Go, npm, uv, and Homebrew, the native commands work and are preferred. A native command cleans the tool's configured location, so Arin asks the tool where that is and validates that path, not a default.
5. **Check what's running right before acting.** Browsers and editors use their caches, ShipIt updates mid-cleanup, `gopls` and Go tests rebuild the cache while it's being removed, booted simulators use their data, and live agent sessions run old tool releases. Arin re-checks running processes, open files, and recent writes anywhere in the tree immediately before each item, not only at scan time.
6. **"Merged" needs squash detection.** Most PRs are squash-merged, so ancestry alone misses them. A worktree counts as merged when HEAD is in the default branch, or a merged PR's head equals HEAD or is ahead of it. A branch with commits after its merged PR is unmerged work, so removal is refused if HEAD has moved since the scan.
7. **Agent worktrees can be alive.** A removed T3 worktree was recreated a minute later by a live thread. Worktrees under `~/.t3/worktrees` start as Review, and any worktree with a process working inside it is blocked.
8. **`bin/` isn't always generated.** It can hold issue notes, scratch source, or a nested git checkout. Arin only considers git-ignored, untracked repo-root `bin/` folders, and marks them Review unless they hold only executables and tool trees with no checkout inside.
9. **`.build` isn't always SwiftPM output.** It can hold a downloaded framework or a review log. Arin requires a sibling `Package.swift` and SwiftPM markers.
10. **Docker's CLI can hang.** `docker system df` can block forever while Desktop is wedged. Every Docker call has a short timeout, `Docker.raw` is never touched directly, and unattached volumes start as Review because they can hold databases. Orphaned `buildx_buildkit_*_state` volumes for deleted builders are safe. Cleanup is pinned to the Docker context that was scanned.
11. **Simulator runtime deletion can leave a mounted image.** The space comes back only after a reboot.
12. **Be clear about what isn't officially supported.** Compacting the Codex log DB is generic SQLite maintenance, not a Codex procedure, and it must not run while Codex writes. For Codex sessions, `codex delete` is the supported route because it removes database and index entries too.
13. **Agent scratch folders can hold real work.** An idle `/tmp/claude-*` folder that was mostly DerivedData also held a git checkout. Temp folders with a checkout anywhere inside start as Review; package-manager checkouts (`SourcePackages/checkouts`, `.build/checkouts`, `pkg/mod`, `node_modules`) don't count. A search that times out or hits an unreadable folder counts as finding one.
14. **A fixed list of locations misses the biggest surprises.** Tens of GB of agent perf artifacts can sit in `~/.t3/userdata/task-artifacts`, outside every known cache path. A size overview of the home folder finds such folders and drills into the subfolder that actually holds the space. It never reports a folder containing a git checkout.
15. **It grows back.** A disk freed by tens of GB can be full again within days, mostly from Go cache, DerivedData, and agent perf artifacts. That's why Arin has low-space alerts and an opt-in Auto mode limited to caches that refill on their own.

## Things that stay hands-off

- Messages, Mail, Photos, iCloud Drive, Documents, Desktop, and Downloads. Point people to System Settings → Storage instead.
- The CoreSpotlight index, Keychains, `~/.ssh`, and cloud credentials.
- Application bundles. Uninstalling apps is the user's call, outside Arin.
