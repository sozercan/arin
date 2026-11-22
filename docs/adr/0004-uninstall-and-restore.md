# 0004: Make uninstall a separate, app-scoped operation

**Status:** Accepted

## Context

Uninstall can touch bundles and user data that a general cleanup never should. Several installed copies can share support data, and one Homebrew cask can install apps the user did not select.

## Decision

- Start only from an app explicitly selected by the user. Check file ownership by bundle ID and by app name only in locations known to use names. Do not take another installed app's files, even with a common bundle-ID prefix. Shared data and weaker name matches start unchecked; short names and ambiguous executable names are not proof of ownership. Diagnostic filenames must have a date directly after the executable name so one app cannot absorb another app's crash reports.
- Revalidate selections and refresh the app catalog, process state, and keep list at execution time. Recheck each item because an app can start or another copy can install during a slow operation. Compare real paths when identifying a bundle or a running process. Move the bundle first so a failed bundle removal does not leave an installed app missing its data.
- Re-query Homebrew; an unanswered query isn't permission to trash a known cask. Use Caskroom links as evidence of where a cask put the app, not the `appdir` in current `brew info` output. Respect renamed or absolute `target:` stanzas and compare with the actual selected bundle. Refuse cask uninstall if it would also remove an unselected app.
- Treat user-writable history as untrusted when putting items back. Verify the source is a direct, nonsymlink child of the Trash and reapply destination checks; an uninstall and an ordinary cleanup do not have identical destination permissions. Reading the Trash is itself subject to macOS privacy permissions.

## Consequences

Some leftovers intentionally stay unselected or cannot be identified. History is a convenience, not a prerequisite for a scan or cleanup; independent processes serialize history writes, append a new line after a torn write, and skip malformed entries on read.
