# 0005: Keep the reviewer advisory and read-oriented

**Status:** Accepted

## Context

The installed agent is useful for paths the rules cannot classify, but it does not need private user data or authority to clean. Provider CLIs expose different controls and output formats.

## Decision

- Send actionable candidates for advice and accept verdicts only for those candidate IDs, never commands or paths. The agent can generally add caution; it can lower risk only on items the rules could not classify, subject to blockers. Do not spend agent time on known safe caches. Default to low effort; an unset model means the CLI's own model. Persist explicit opt-out separately from an unset preference, which can pick an installed agent on launch.
- Request read-only access and avoid shell grants where the command prefix can also match writes or bypass file-read denials. Copilot's coarse Git prefix matching cannot authorize `git worktree list` in isolation. Restrict its inputs to existing candidate directories, excluding home and directories overlapping private roots after symlink and case normalization. A missing path or file can make its directory option fail the whole review.
- Prefer structured provider output where available; provider envelopes can also return the result as text. Decode it into the verdict schema and never let text outside that schema influence cleanup actions.

## Consequences

Results are advisory even if a CLI can return valid JSON. The reviewer cannot supersede action construction or executor checks. Provider restrictions should be assessed against the CLI being shipped, not treated as a guarantee independent of its behavior.
