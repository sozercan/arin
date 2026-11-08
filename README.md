# Arin

Arin is a native macOS app that finds disk space that's safe to reclaim on a developer Mac. Your own coding agent, Claude Code or Codex, double-checks the findings. Nothing is removed until you tick it.

- **Knows where developer Macs hide space.** Go/npm/uv/pnpm/bun/Homebrew caches, Xcode DerivedData, simulators and runtimes, stale temp build folders, old Codex/Claude releases and unused mise tool versions, project build output (`node_modules`, `.build`, venvs, Cargo `target`, `.next`, Gradle `build`, `.dart_tool`, Zig caches, `.terraform`, and any folder a tool tagged with `CACHEDIR.TAG`), merged git worktrees (including squash merges), Docker build cache and orphaned volumes, Lima/Colima downloads, Ollama and LM Studio models, and Time Machine local snapshots. A quick size overview of the rest of your home folder surfaces any other large folder (agent task output, logs, app data) under Unclassified.
- **Your agent checks what the rules can't settle.** After each scan, Arin automatically hands the uncertain items (anything not rule-safe, plus everything unclassified) to Claude Code or Codex in a read-only mode. You can turn this off in Settings. The agent returns *safe / review / keep* with a reason per item. It can't run commands that change anything, and it can't add actions. Arin's rules and guardrails decide what can be done. Claude Code is also denied reads of credentials and personal folders (`~/.ssh`, `~/.aws`, keychains, cookies, Mail, Messages, Documents). Codex's read-only sandbox blocks writes and network access but not reads, so for Codex that rule lives only in the prompt. Reviews default to a cheaper setup (Sonnet at low effort for Claude Code, your configured model at low effort for Codex). You can change this in Settings. Signed in with a Claude plan, reviews count toward your plan's usage limits.
- **You choose, then Arin re-checks.** Right before each item, Arin checks running apps and open files again and refuses protected locations. It uses each tool's own cleanup command where one works. Build output in a project you changed in the last 7 days is listed but not pre-selected.
- **Always keep.** Right-click an item and choose Always Keep (or `arin keep <id>`). Kept items are never pre-selected, never sent for review, and refused by the cleaner. If the keep list can't be read, Arin cleans nothing until it's fixed.
- **History.** Arin remembers each scan and cleanup: what grew back since the previous scan, free space over time, what each cleanup freed, and Put Back for anything it moved to the Trash.
- **Honest numbers.** Folder sizes overstate what deleting frees, because of APFS clones and snapshots. Arin measures the real change in free space and explains any gap.
- **Space map.** A treemap of everything the scan found, by category; click a tile to select it.
- **Stays out of the way.** A menu bar gauge, an alert when free space drops below your threshold, an opt-in Auto mode that clears only caches that refill on their own, and an Open at login setting so they keep running after a restart.

## Cleanup levels

| Level | Includes |
|---|---|
| Quick | Caches that refill on their own: package caches, idle DerivedData, unavailable simulators, stale temp folders, old tool versions |
| Standard | Adds build output (`node_modules`, `.build`, venvs, `bin/`), merged worktrees, Docker build cache, app caches |
| Deep | Adds simulator data, old runtimes, extra toolchains, archives, local AI models, Time Machine local snapshots, unrecognized app data |

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

## Releasing

Push a version tag; `.github/workflows/release.yml` does the rest:

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The workflow runs the tests, builds a universal app stamped with the tag's version, and signs it with the best identity it has: Developer ID Application, then Apple Development, then ad hoc. A Developer ID build also gets a signed, notarized, and stapled DMG. It then publishes a GitHub release with notes from `git log` and the DMG's SHA-256. For stable versions, it updates `Casks/arin.rb` in `sozercan/homebrew-repo`, which installs the app and links the `arin` CLI. Tags with `-alpha`, `-beta`, `-rc`, or `-dev` become prereleases and leave the cask alone. Running the workflow by hand builds and notarizes without publishing anything.

| Secret | Used for |
|---|---|
| `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PWD`, `MACOS_KEYCHAIN_PWD` | Base64 `.p12` signing identity, its password, and a password for the temporary keychain |
| `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID` | Notarization (required once a Developer ID certificate is configured) |
| `HOMEBREW_REPO_TOKEN` | Pushing the cask to the tap |

Without a Developer ID certificate, releases aren't notarized and Gatekeeper warns on first launch; the cask clears the quarantine flag. Privacy permissions such as Full Disk Access are tied to the signature, so an ad-hoc build loses them on every update. Homebrew can only download releases from a public repository, so the cask step is skipped while this one is private.

## CLI

The same engine runs headless:

```bash
swift run arin scan --level standard          # read-only
swift run arin review --agent claude          # scan + agent verdicts, read-only
swift run arin review --agent codex --effort medium   # override review model/effort
swift run arin clean --level quick            # dry run
swift run arin clean --level quick --yes      # actually clean pre-selected items
swift run arin clean --ids 'go.build-cache:go.build-cache' --yes
swift run arin plan --level quick --out plan.json   # save what clean would pick
swift run arin clean --plan plan.json --yes         # rescan, then run only unchanged items
swift run arin keep 'docker.volume:pgdata'          # never clean this; `arin keep` lists, --remove undoes
swift run arin history                              # past cleanups and what grew since the last scan
```

A saved plan lists candidate IDs with the action each one had. Running it rescans and refuses any item that's gone, whose action changed (a worktree with a new commit, a new snapshot), that became more cautious, or that's on the keep list.

### Using arin from your agent

`arin skill` prints a skill file that teaches Claude Code, Codex, or another agent to scan with `--json`, summarize, and clean only the IDs you approve:

```bash
mkdir -p ~/.claude/skills/arin && arin skill > ~/.claude/skills/arin/SKILL.md
```

The agent never gets anything more than the CLI: actions still come from Arin's rules, and the cleaner re-checks everything.

## How it's put together

- `Sources/ArinCore`: rules (`Rules/`, `Catalog.swift`), scanner, guardrails, executor, agent reviewer, and the keep list, history and plans (`Store.swift`, kept in `~/Library/Application Support/<bundle ID>`).
- `Sources/ArinApp`: the SwiftUI app (window, menu bar extra, settings).
- `Sources/arin-cli`: the `arin` command.
- `docs/learnings.md`: what real cleanups showed, and why each rule and guardrail exists.
