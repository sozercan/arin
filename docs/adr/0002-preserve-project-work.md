# 0002: Require evidence that project work can be recovered

**Status:** Accepted

## Context

Git's ordinary status omits ignored files and changes hidden by index flags. An editable install, a build cache, or agent scratch space can contain a separate repository with no remote copy of its work. Conversely, a clean child build cache can be removable even if its enclosing worktree is not.

## Decision

- Require worktrees to be merged by ancestry or by a qualifying merged PR's head, to account for squash merges. Recheck the reviewed HEAD and hidden work immediately before removal. Never force Git to remove a worktree; read-only caches can make Git fail partway through, and Arin's manual finish is limited to that fallback path and an unregistered or prunable worktree.
- Protect ignored nested repositories and on-disk paths marked assume-unchanged or skip-worktree; sparse-checkout entries absent from disk cannot hold local edits. Git can list the parts of a partly ignored folder without listing the folder or its `.git` entry, so check the enclosing directories too. Recognize bare and shared Git directories; use NUL-delimited output for file names that can contain newlines. Treat an unreadable `.git` entry or incomplete search as uncertainty, not clearance.
- Require git-ignored, untracked output when inside a repository, and distinguish tool-owned layouts from generic names like `build` or `bin`. Keep looking for nested projects inside generic `build` folders. Do not let a worktree candidate claim its build-cache descendants. An idle temp folder is not necessarily regenerable; only recognized build layouts start safe, and the children of busy temp directories can be judged independently. The home overview uses `du` to locate large folders, not to estimate reclaimable bytes, and avoids paths already claimed and folders containing Git work. It does not offer an entire top-level home directory for removal.
- Recognize SwiftPM scratch areas by their standard slots or state markers, including custom build paths. A checkout must point to its local mirror, not a remote, to keep scans bounded and usable offline. Compare local branches, tags and HEAD with the mirror's current refs, not stale remote-tracking refs. A `.git` file or symlink is not SwiftPM's own checkout directory. DerivedData must protect edited `SourcePackages` even if the project is gone; only a definite missing workspace on a mounted volume is evidence of orphaning.
- Observe project activity without updating it: strip environment overrides that can redirect Git and disable optional index writes, which would otherwise make every status probe look like recent work. Ignore generated output as an activity signal. Include Claude Code transcripts because a read-only agent session need not touch a project file; the transcript folder name is derived from the working directory by replacing non-ASCII-alphanumeric characters with hyphens.

## Consequences

Arin can list rebuildable artifacts without assuming everything inside a project or cache is disposable. The observed failure cases and rule-specific exceptions are recorded in [cleanup learnings](../learnings.md).
