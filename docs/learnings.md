# What real cleanups taught us

Arin's rules come from seven hands-on disk cleanups on a developer Mac (460 GB SSD, often above 95% full), run with coding agents between September and November 2026. This file records what happened, so rule changes can be checked against evidence.

## Where the space went

| Source | Typical size | Notes |
|---|---:|---|
| Go build cache (`~/Library/Caches/go-build`) | 5–21 GB | Grew about 20 GB in 9 hours while agents built and tested many worktrees in parallel. Go only trims entries unused for ~5 days and has no size cap. |
| Per-run Go caches in `$TMPDIR` and `/tmp` | 3–18 GB | One-off `GOCACHE` dirs such as `orka-ahp-merge-gocache` and `go-build-connectors-lint`. |
| Xcode DerivedData, including copies in `$TMPDIR` | 2–26 GB | Each perf run kept its own 2.7 GB build. |
| Simulator device data | 5–26 GB | Includes devices left unavailable after runtime upgrades. |
| Duplicate or beta simulator runtimes | 8–18 GB each | A beta runtime (`24B91016s`) next to the release build of the same version. |
| Git worktrees | 6–26 GB that were merged and clean | 279 linked worktrees across 30 repos. Most of the size is repeated `bin/`, `.build`, and `node_modules`. |
| Repo-root `bin/` folders | Up to 30 GB | Envtest `bin/k8s` (13 GB across 80 copies), linters, controller-gen, Python test environments. |
| `node_modules` / Swift `.build` | 6–17 GB / 4–13 GB | Repeated in every worktree. |
| Package caches | 12–18 GB | uv 6 GB, pnpm 6 GB, Homebrew 2.4 GB, bun 2 GB, npm 1.6 GB, trivy, golangci-lint, SwiftPM, Yarn. |
| Old tool releases | 3–4 GB | 10–14 old Codex releases, old Claude Code and Copilot versions, unused Rust toolchains. |
| Agent data | 17–56 GB | Codex sessions (up to 29 GB), a log database with 16 GB of free pages, review and validation folders. |

## Rules that came from mistakes

1. **Measure free space, not folder sizes.** `du` counts APFS clones and shared blocks in full. Deleting 12.2 GB of session files freed 4.6 GB. Removing unavailable simulators freed about nothing. Code-signing clones reported 78 GB that was mostly shared. Arin reports the measured change in free space and explains any gap.
2. **Snapshots hold deleted files.** A staged macOS update created `com.apple.os.update-*` and `MSUPrepareUpdate` snapshots mid-session, and gains stopped showing up. Never delete Preboot, `/System/Library/AssetsV2`, or update snapshots by hand. Finish the update and restart instead.
3. **Read-only trees break `rm`.** Go module caches and envtest binaries are read-only, and this failed in nearly every session (worktree removal, `bin/`, `.build`, worktrunk trash). Arin retries once after `chmod -R u+w`.
4. **Native cleanup commands don't always work:**
   - `pnpm store prune` freed nothing while deleted projects were still registered.
   - `bun pm cache rm` refuses to run outside a project.

   Arin deletes those two stores directly. For Go, npm, uv, and Homebrew, the native commands work and are preferred.
5. **Check what's running right before acting.** Problems included Chrome and VS Code Insiders using their caches, ShipIt mid-update, `gopls` and Go tests rebuilding the cache during cleanup, three booted Helio simulators, and Codex releases used by live sessions. Arin re-checks running processes and open files immediately before each item, not only at scan time.
6. **"Merged" needs squash detection.** Most PRs were squash-merged, so ancestry alone misses them. A worktree counts as merged when HEAD is in the default branch, or a merged PR's head equals HEAD or is ahead of it. A branch with commits after its merged PR is unmerged work.
7. **T3 and agent worktrees can be alive.** A removed T3 worktree was recreated a minute later by a live thread. Worktrees under `~/.t3/worktrees` start as Review, and any worktree with a process working inside it is blocked.
8. **`bin/` isn't always generated.** Some held issue notes, scratch source, or a nested git checkout. Arin only considers git-ignored, untracked repo-root `bin/` folders, and marks them Review unless they hold only executables and tool trees.
9. **`.build` isn't always SwiftPM output.** One held a downloaded Sparkle framework, and another held a review log. Arin requires a sibling `Package.swift` and SwiftPM markers.
10. **Docker's CLI can hang.** `docker system df` never returned while Desktop was wedged. Every Docker call has a short timeout, `Docker.raw` is never touched directly, and unattached volumes start as Review because they can hold databases. Orphaned `buildx_buildkit_*_state` volumes for deleted builders are safe.
11. **Simulator runtime deletion can leave a mounted image.** The space came back only after a reboot.
12. **Be clear about what isn't officially supported.** Compacting the Codex log DB is generic SQLite maintenance, not a Codex procedure, and it must not run while Codex writes. For Codex sessions, `codex delete` is the supported route because it removes database and index entries too.
13. **It grows back.** After about 85 GB was freed, the disk was full again two days later, mostly from Go cache, DerivedData, and agent perf artifacts. That's why Arin has low-space alerts and an opt-in Auto mode limited to caches that refill on their own.

## Things that stay hands-off

- Messages, Mail, Photos, iCloud Drive, Documents, Desktop, and Downloads. Point people to System Settings → Storage instead.
- The CoreSpotlight index, Keychains, `~/.ssh`, and cloud credentials.
- Application bundles. Uninstalling apps is the user's call, outside Arin.
