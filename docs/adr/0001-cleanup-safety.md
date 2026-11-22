# 0001: Revalidate cleanup at the point of action

**Status:** Accepted

## Context

A scan, a saved plan, and a review verdict describe a past state. An earlier cleanup can take long enough for a process to start or for the CLI to protect a path. Paths can also change meaning through aliases, symlinks, configuration, or a newly mounted volume.

## Decision

- Only rules construct actions. In the app, carry forward verdicts that add caution, not ones that rated a previous snapshot of the data safe. Auto mode is opt-in and only selects regenerable caches, not project output or worktrees.
- Refresh process and open-file state and reload the keep list for each item. When open-file state is unavailable, refuse actions with paths. Refuse cleanup if the keep list cannot be read; only an absent file means an empty list. Explicit selection cannot override a keep-list refusal. Check both open files and recent writes because the snapshot cannot tell when otherwise closed files were modified.
- Record kept paths before deduplication and size filtering so a parent cleanup cannot remove a kept descendant. Compare real paths, including symlink and case aliases; err toward refusing even when removing only a symlink would be harmless. Serialize state updates across app and CLI. If paths cannot be saved, keep the scan's protection in memory rather than clearing it on reload.
- Resolve symlinked ancestors and check both spellings against the guardrails. Direct removal unlinks a leaf symlink; native commands can follow it, so validate its target too. Allow narrow command shapes where other subcommands could affect unrelated data. Compare canonical `/var` and `/tmp` spellings and case aliases so they cannot bypass path protections.
- Reject a path on or containing another mount and fail closed if mounts cannot be listed. Delete relative to pinned directory descriptors without following symlinks, and check the device again during descent. For user-owned read-only folders, change mode only through a verified open descriptor; never chmod files or an unopened folder by name. Continue past individual failures and use bounded retries when a writer refills a directory during deletion.
- Re-run rule-specific safety checks before acting. Use the tool's own command when it can do the job safely. Pin Docker actions to the scanned context and do not assume a Buildx volume is orphaned when its owners cannot be listed. Ask npm where its active cache is before offering cleanup. For Bun, delete cache entries instead of the root so its global `links/` store survives even if it appears after the scan. Refuse mise pruning if its dry run fails or a config mise ignored might still exist: otherwise installed versions still pinned by that config appear unused.
- Keep Docker probes bounded because a wedged daemon can hang the CLI. Use Ollama's own removal command so model manifests and shared layers stay consistent. Require more than a single generically named `Cache` folder as evidence of an Electron cache, and account for workspace partitions. Keep the latest simulator runtime per platform; at the same version, prefer a release build to a beta. See [cleanup learnings](../learnings.md) for the evidence behind these rules.
- Count a process's working directory as busy even without a file open in it. For caches named after apps, err toward recognizing a running bundle when its name and executable differ. For temporary directories, inspect only bounded prefixes of regular marker files; following a symlink or opening a FIFO could escape the probe or block it. The Darwin temp layout places caches and code-signing clones beside the per-user temporary directory, not below it.
- Reject the entire explicit ID selection if any ID is unknown; do not trim path-derived IDs or silently take the last of repeated value flags. A saved plan is narrowed, never extended, by explicit IDs. Rescan before running it and compare the fresh action, risk, and target paths: a native command may be unchanged even when its configured cache moved.

## Consequences

Checks can refuse a cleanup that would have been safe, and per-item refresh costs time. Prefer that to silently deleting unreviewed data. Keep evidence for rule and guardrail changes in [cleanup learnings](../learnings.md).
