# Arin

Arin is a native macOS app that finds disk space that's safe to reclaim on a developer Mac. Your own coding agent, Claude Code or Codex, double-checks the findings. Nothing is removed until you tick it.

- **Knows where developer Macs hide space.** Go/npm/uv/pnpm/bun/Homebrew caches, Xcode DerivedData, simulators and runtimes, stale temp build folders, old Codex/Claude releases, `node_modules`/`.build`/venvs, merged git worktrees (including squash merges), Docker build cache and orphaned volumes. A quick size overview of the rest of your home folder surfaces any other large folder (agent task output, logs, app data) under Unclassified.
- **Your agent checks what the rules can't settle.** After each scan, Arin automatically hands the uncertain items (anything not rule-safe, plus everything unclassified) to Claude Code or Codex in a read-only mode. You can turn this off in Settings. The agent returns *safe / review / keep* with a reason per item. It can't run commands that change anything, and it can't add actions. Arin's rules and guardrails decide what can be done. Claude Code is also denied reads of credentials and personal folders (`~/.ssh`, `~/.aws`, keychains, cookies, Mail, Messages, Documents). Codex's read-only sandbox blocks writes and network access but not reads, so for Codex that rule lives only in the prompt. Reviews default to a cheaper setup (Sonnet at low effort for Claude Code, your configured model at low effort for Codex). You can change this in Settings. Signed in with a Claude plan, reviews count toward your plan's usage limits.
- **You choose, then Arin re-checks.** Right before each item, Arin checks running apps and open files again and refuses protected locations. It uses each tool's own cleanup command where one works.
- **Honest numbers.** Folder sizes overstate what deleting frees, because of APFS clones and snapshots. Arin measures the real change in free space and explains any gap.
- **Stays out of the way.** A menu bar gauge, an alert when free space drops below your threshold, and an opt-in Auto mode that clears only caches that refill on their own.

## Cleanup levels

| Level | Includes |
|---|---|
| Quick | Caches that refill on their own: package caches, idle DerivedData, unavailable simulators, stale temp folders, old tool versions |
| Standard | Adds build output (`node_modules`, `.build`, venvs, `bin/`), merged worktrees, Docker build cache, app caches |
| Deep | Adds simulator data, old runtimes, extra toolchains, archives, unrecognized app data |

Only items marked **Safe** at or below the chosen level are pre-selected. Agent verdicts can make an item more cautious. They can make it less cautious only for items no rule recognizes.

## Build

Requires macOS 26 and Xcode 26 or later. Arin has no third-party dependencies.

```bash
swift build
swift test
Scripts/build-app.sh          # builds build/Arin.app (ad-hoc signed)
Scripts/verify-app.sh         # checks the bundle: ID, binaries, signature, bundled CLI
open build/Arin.app
```

`ARCHES="arm64 x86_64" Scripts/build-app.sh` builds a universal app. The version comes from `version.env`. Debug builds use the bundle ID `com.sertacozercan.Arin.debug`, so they keep their own settings. CI runs the tests and packages a universal app for every change to code or scripts.

## CLI

The same engine runs headless:

```bash
swift run arin scan --level standard          # read-only
swift run arin review --agent claude          # scan + agent verdicts, read-only
swift run arin review --agent codex --effort medium   # override review model/effort
swift run arin clean --level quick            # dry run
swift run arin clean --level quick --yes      # actually clean pre-selected items
swift run arin clean --ids 'go.build-cache:go.build-cache' --yes
```

## How it's put together

- `Sources/ArinCore`: rules (`Rules/`, `Catalog.swift`), scanner, guardrails, executor, and agent reviewer.
- `Sources/ArinApp`: the SwiftUI app (window, menu bar extra, settings).
- `Sources/arin-cli`: the `arin` command.
- `docs/learnings.md`: what real cleanups showed, and why each rule and guardrail exists.
