<div align="center">

<img src="docs/images/icon.png" width="128" height="128" alt="Arin app icon">

# Arin

**Reclaim disk space on your developer Mac, with your coding agent as a second opinion.**

[![Latest release](https://img.shields.io/github/v/release/sozercan/arin?label=release&color=7c5cf6)](https://github.com/sozercan/arin/releases/latest)
[![CI](https://github.com/sozercan/arin/actions/workflows/ci.yml/badge.svg)](https://github.com/sozercan/arin/actions/workflows/ci.yml)
![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)

</div>

Arin is a native macOS app that finds space that's safe to reclaim: package caches, build output, stale simulators, merged worktrees, idle Docker data, old models. Rules decide what each item is. Claude Code, Codex, or GitHub Copilot double-checks anything the rules can't settle. Nothing is removed until you tick it.

## Install

```bash
brew install --cask sozercan/repo/arin
```

This installs **Arin.app** and links the `arin` command-line tool. To update later:

```bash
brew upgrade --cask arin
```

<details>
<summary>Install without Homebrew</summary>

Download the DMG from the [latest release](https://github.com/sozercan/arin/releases/latest) and drag Arin to Applications. Releases aren't notarized yet, so macOS blocks the first launch: open **System Settings → Privacy & Security** and click **Open Anyway**. Homebrew handles this for you.

</details>

**Requirements:** macOS 26 or later. For agent reviews, install [Claude Code](https://docs.claude.com/en/docs/claude-code), [Codex](https://github.com/openai/codex), or [GitHub Copilot CLI](https://github.com/github/copilot-cli). Arin works without any of them; it just skips the second opinion. To turn reviews off while one is installed, set *Review with* to *None* in Settings.

## How it works

1. **Scan.** Arin looks where developer Macs hide space and sorts every item into a cleanup level, with a reason.
2. **Review.** Items the rules can't settle go to your coding agent in a read-only mode. It returns *safe*, *review*, or *keep*, with a reason for each.
3. **Clean.** You pick. Right before each item, Arin re-checks running apps and open files, refuses protected locations, and uses the tool's own cleanup command where one works. Then it reports how much free space actually changed.

## What it finds

| Where | What |
|---|---|
| **Package caches** | Go, npm, uv, pnpm, bun, Homebrew |
| **Xcode** | DerivedData, simulators and runtimes, archives |
| **Project build output** | `node_modules`, `.build`, venvs, Cargo `target`, `.next`, Gradle `build`, `.dart_tool`, Zig caches, `.terraform`, and any folder tagged with `CACHEDIR.TAG` |
| **Git worktrees** | Worktrees whose branch was merged, including squash merges |
| **Containers & VMs** | Docker build cache and orphaned volumes, Lima and Colima downloads |
| **Local AI models** | Ollama and LM Studio |
| **Tool versions** | Old Codex, Claude and Copilot CLI releases, unused mise versions, extra Rust toolchains |
| **Agent data** | Codex sessions idle for 30 days (removed with `codex delete`), Claude Code data for folders that no longer exist (`claude purge`), bloated agent databases |
| **System** | Stale temp folders (Go caches and DerivedData copies start as Safe; anything else as Review), Time Machine local snapshots |
| **Everything else** | A size overview of your home folder surfaces other large folders (agent output, logs, app data) under *Unclassified* |

## Cleanup levels

| Level | Includes |
|---|---|
| **Quick** | Caches that refill on their own: package caches, idle DerivedData and DerivedData for deleted projects, unavailable simulators, stale temp caches, old tool versions |
| **Standard** | Adds build output (`node_modules`, `.build`, venvs, `bin/`), merged worktrees, Docker build cache, app caches |
| **Deep** | Adds simulator data, old runtimes, extra toolchains, archives, local AI models, Time Machine local snapshots, agent history, unrecognized app data |

Only items marked **Safe** at or below the chosen level are pre-selected. Build output in a project you changed, or ran a Claude Code session in, during the last 7 days is listed but not pre-selected.

## Built to be careful

- **The agent can only advise.** It can't run commands that change anything or add actions; Arin's rules and guardrails decide what can be done. Agent verdicts can make an item more cautious, and less cautious only for items no rule recognizes.
- **Private folders stay private.** Claude Code is denied reads of credentials and personal folders (`~/.ssh`, `~/.aws`, keychains, cookies, Mail, Messages, Documents). Codex's read-only sandbox blocks writes and network access but not reads, so for Codex that rule lives only in the prompt. GitHub Copilot can only list and read the folders under review, and never your home folder as a whole or the private folders above.
- **Nothing that holds work.** Build output and temp folders are refused when git doesn't ignore them, tracks files in them, or a repository inside could hold commits that exist nowhere else (a clone in `.venv/src`, an edited SwiftPM checkout, a bare clone). A merged worktree is refused when an ignored folder in it holds a repository or a file is marked assume-unchanged or skip-worktree. Each check runs again right before the item is removed.
- **Never crosses volumes.** A folder with a disk image, network share, or other volume mounted inside it is refused, and deletes never follow symlinks. If part of an item can't be removed, Arin says what was left and why.
- **Fails closed.** If Arin can't list open files, can't search a folder for repositories, or mise reports a tracked config it can't load, the item isn't cleaned.
- **Always Keep.** Right-click an item and choose *Always Keep*. Kept items are never pre-selected, never sent for review, and refused by the cleaner, even when reached through another path or a symlink. If the keep list can't be read, Arin cleans nothing.
- **Honest numbers.** Sizes count only the blocks deleting an item frees: an APFS clone whose original stays behind, or a hard link with another link elsewhere, counts for almost nothing, unlike in `du`. Snapshots can still hold deleted blocks, so Arin measures the real change in free space and explains any gap.
- **Put Back.** Anything moved to the Trash can be restored from History.

## In the app

- **Space map.** A treemap of everything the scan found, by category. Click a tile to select it.
- **History.** Each scan and cleanup: what grew back, free space over time, and what each cleanup freed.
- **Menu bar gauge.** Free space at a glance, with an alert when it drops below your threshold.
- **Uninstall apps.** *Applications* lists your apps by size. Double-click one, or drop it on the window, to see the preferences, caches, containers and other files it keeps in `~/Library`, then move them to the Trash with it. Files matched only by name, or shared with the developer's other apps, start unchecked. Homebrew apps are removed with `brew uninstall --cask`, and Apple's apps aren't offered.
- **Auto mode.** Opt in, and when free space runs low Arin clears only caches that refill on their own. Turn on *Open at login* to keep it running after a restart.

Reviews run automatically after each scan; you can turn them off in Settings. They default to a light setup (Sonnet at low effort for Claude Code, your configured model at low effort for Codex and GitHub Copilot), which you can change there too. With a Claude plan, reviews count toward your plan's usage limits. With GitHub Copilot, they use your plan's AI credits.

## Command line

The same engine runs headless. Everything is read-only or a dry run until you pass `--yes`.

```bash
arin scan --level standard                 # find candidates
arin review --agent claude                 # scan, then ask your agent
arin clean --level quick                   # dry run: show what would go
arin clean --level deep --older-than 90    # dry run: agent sessions untouched for 90+ days
arin clean --level quick --yes             # clean the pre-selected items
arin clean --ids 'go.build-cache:go.build-cache' --yes
arin plan --level quick --out plan.json    # save what clean would pick
arin clean --plan plan.json --yes          # rescan, then run only unchanged items
arin keep 'docker.volume:pgdata'           # never clean this (--remove undoes)
arin history                               # past cleanups and what grew back
arin apps                                  # apps you can uninstall
arin uninstall Slack                       # dry run: the app and the files it keeps
arin uninstall Slack --yes                 # move them to the Trash
arin disk --warn-below 20GiB               # print a warning only when free space is low
```

A saved plan is re-checked when it runs: any item that's gone, changed (a worktree with a new commit, a new snapshot, a moved npm cache), became more cautious, or was kept since is refused. `clean --plan` rescans with the `--older-than` you pass it, so pass the value that made the plan. If a different age changes which agent sessions qualify, that item is refused as changed. If it picks the same sessions, they meet both ages and the item runs. Run `arin --help` for every option.

### From your agent

`arin skill` prints a skill that teaches Claude Code, Codex, or another agent to scan with `--json`, summarize, and clean only the IDs you approve:

```bash
mkdir -p ~/.claude/skills/arin && arin skill > ~/.claude/skills/arin/SKILL.md
```

The agent gets nothing beyond the CLI: actions still come from Arin's rules, and the cleaner re-checks everything.

To have Claude Code warn you when the disk is nearly full, add a `SessionStart` hook to `~/.claude/settings.json`. `arin disk --warn-below` prints only when free space is lower and always exits 0:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "arin disk --warn-below 20GiB" }] }]
  }
}
```

## Uninstall

```bash
brew uninstall --cask --zap arin
```

`--zap` also removes Arin's preferences. History and the keep list live in `~/Library/Application Support/com.sertacozercan.Arin`.

## Contributing

Build instructions, project layout, and how rules are added are in [CONTRIBUTING.md](CONTRIBUTING.md). [docs/learnings.md](docs/learnings.md) explains why each rule and guardrail exists.
