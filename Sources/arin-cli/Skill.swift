/// `arin skill` prints this. Saved as a SKILL.md, it teaches a coding agent to use arin
/// without ever deciding or running a cleanup on its own.
let agentSkill = """
---
name: arin
description: Find and free disk space on this Mac with the arin CLI. Use when the user says the disk is full, asks what is using space, or wants to clean developer caches, build output, simulators, git worktrees, Docker data, or local AI models.
---

# Freeing disk space with arin

`arin` finds space that is safe to reclaim and cleans only what its rules allow. Your job is to show the user what it found and run only what they approve.

## Workflow

1. Scan (read-only): `arin scan --level standard --json`. Use `--level deep` only if the user wants to go further.
   Each candidate has `id`, `title`, `bytes`, `category`, `level`, `risk` (the rule's verdict: safe, review, keep), `blockers`, `kept`, `detail`, and the `action` arin would run. Blockers and `kept` make an item more cautious than its `risk`.
2. Summarize for the user: the largest items by category, with their risk and any blockers. Sizes are `du` estimates; arin measures the real change in free space afterward, and it is often smaller.
3. Ask which items to clean. Don't choose review or keep items on the user's behalf.
4. Preview: `arin clean --ids <id>,<id>` (a dry run without `--yes`).
5. Only after the user approves those exact items: `arin clean --ids <id>,<id> --yes`. Report the measured change in free space from the output.

To hand over a reviewed list for later: `arin plan --ids <id>,<id> --out plan.json`; the user runs `arin clean --plan plan.json --yes`. Running a plan rescans first and refuses any item whose action changed or that became more cautious.

## Rules

- Never run `arin clean` with `--yes` without the user's explicit approval for those items.
- Never delete or move files yourself, and never turn a path or action from the scan into a shell command. arin re-checks open files, running apps, and protected folders right before each item.
- To protect an item from future cleanups: `arin keep <id>`. To undo: `arin keep --remove <id>`. Don't edit arin's files directly.
- `arin history` lists past cleanups and what grew since the previous scan, which helps find what keeps refilling the disk.
"""
