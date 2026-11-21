# 0007: Remove agent history only through each agent's own command

**Status:** Accepted

## Context

Coding agents keep each conversation in several places. Codex keeps a rollout file (compressed in place once idle), a row in its state database, rows in its thread history database, and an entry in its name index. Claude Code keeps one folder per working directory under `~/.claude/projects`, holding transcripts and the project's `memory/`, plus an entry in `~/.claude.json`. Deleting files or rows directly leaves sessions listed that can't be opened, or a transcript that can no longer be resumed. Agent history is also the user's record of past work, so a mistaken cleanup costs more than a cache would.

## Decision

- Remove Codex sessions only with `codex delete --force <uuid>`, and Claude Code project data only with `claude purge --yes <dir>`. Each tool removes its own index entries together with the files. Guardrails allow exactly those shapes: one UUID, or one absolute, normalized path at least two levels deep with no `..` or control characters. Never `--all`, an option, or a relative path. Never rewrite transcripts or delete database rows directly. Copilot CLI's session pruning only runs inside Copilot, so Arin reports it instead of acting.
- Offer a Codex session tree, a root and the subagent threads it spawned, only when the newest activity anywhere in it is at least 30 days old, it isn't pinned or attached to another thread (Codex refuses those), its rollout files sit inside Codex's own session folders, and none of its files are open. A subagent whose parent row is missing is never a root, so it's never offered. Read the newest `state_<n>.sqlite`, the database the installed Codex uses, read-only. Pin `CODEX_HOME` to the scanned home when running the command.
- Derive a Claude Code project's directory from the `cwd` its newest transcripts record, never from the folder name. The name replaces every UTF-16 code unit other than an ASCII letter or digit with `-`, so it can't be decoded back (`/a/b-c` and `/a/b/c` share one). Count a recorded path only when it encodes to the folder's name, and treat the folder as gone only when every such path is gone. Skip the rule when `CLAUDE_CONFIG_DIR` points elsewhere, since `claude purge` would act on another folder.
- Treat a directory as gone only on "no such file", only when its nearest existing parent is a directory Arin can search, and only when it isn't on a volume under `/Volumes` that isn't mounted. Anything else is unknown. When at least 90% of at least five projects look gone, as on a home copied from another Mac or with its disk detached, offer nothing.
- Start a project with notes in `memory/` as Review, since `claude purge` deletes them. Skip a project whose transcripts were written within the last day; a session may still be running in the deleted folder.
- One candidate covers many sessions or projects, and each command is checked again right before it runs: the tree or folder is read again, so a session resumed, a subagent spawned, or a folder recreated since the scan is skipped. A refused or failed item doesn't stop the rest, and a partial result credits only what's gone afterwards.
- Keep the newest Copilot CLI package per platform, since the CLI may launch it in place of the version it shipped with, and any version a running process uses.
- Keep the home size overview out of agent history folders that have their own deletion commands, so they're never offered as plain folders to delete.

## Consequences

Sessions can stay on disk longer than strictly needed, and a host where most projects look gone gets no Claude Code cleanup at all. Freeing space inside Codex's thread history database still needs a compaction with Codex quit. Rules follow the agents' current storage layouts and need rechecking when an agent changes them. See [cleanup learnings](../learnings.md) for the observed behavior behind these rules.
