---
name: delete-comment
description: Audit and remove Arin source comments, migrate non-obvious decisions to ADRs, file follow-ups for implementation debt, and tighten the comment lint ratchet. Use for a requested comment sweep, not for general code review or automatic refactoring.
---

# Delete comments

Run `Scripts/check-comments.sh --inventory` from the repository root. For a scoped request, review only its files. Read surrounding code and tests before classifying; adjacent comment lines can be one thought. Ignore comment-like literal text and the tool metadata documented in `CONTRIBUTING.md`.

| Category | Action |
| --- | --- |
| Tautology | Delete restatement, navigation marker, or test narration already visible in the code. |
| Stale | Check the current behavior and delete obsolete or misleading claims. |
| Excuse | Delete the explanation and file a follow-up for the concrete implementation gap; do not silently fix it in the sweep. Check for an existing issue first. Include code evidence, the impact, and a testable outcome, and write only to the authorized tracker. |
| Decision Record | Add the context, decision, and tradeoff to the most relevant ADR in `docs/adr/`, or create a focused ADR. Cite `docs/learnings.md` for existing cleanup evidence rather than duplicating it. Then remove the comment. |

Leave executable behavior and literal strings alone. Remove the exact allowances for any retired comments from `.comment-baseline.json`; never add entries or just change their text to make CI green. Verify with `Scripts/check-comments.sh --base <base-revision>`, `git diff --check`, and focused tests where a removal could affect parsing or behavior. Never run a real cleanup for verification.

Report the categories, ADRs, and issue links. Count fully removed comment lines separately from inline comments, which don't reduce line count, and from any remaining ratcheted comments or mandatory metadata.
