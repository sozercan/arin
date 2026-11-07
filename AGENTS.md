# AGENTS.md

Arin is a native macOS (SwiftUI, Swift 6, macOS 26+) disk-cleanup app with a CLI over the same core. No third-party dependencies.

## Build & test

```bash
swift build
swift test
Scripts/build-app.sh debug   # build/Arin.app, bundle ID com.sertacozercan.Arin.debug
Scripts/verify-app.sh --bundle-id com.sertacozercan.Arin.debug
swift run arin scan          # read-only scan of this Mac
```

- `version.env` is the single source for the app version; release builds overwrite it from the tag.
- Debug builds must keep the `.debug` bundle ID so they never share settings with an installed copy.
- Pin GitHub Actions to a full commit SHA with the version in a comment.
- The bundled CLI lives at `Contents/Helpers/arin` (not `MacOS/`, which would collide with `Arin`). Sign it before the app.
- Releases come only from pushed `v*` tags. A manual run of the release workflow must not publish.

## Rules for changes

- Read `docs/learnings.md` before adding or changing a rule. Every rule should trace back to observed behavior.
- Actions come only from rules. Agent output is verdicts by candidate ID and must never become a command or a path.
- Executor guardrails (`Guardrails.swift`) are the last line of defense: keep protected paths and the command allowlist strict, and add a test for any change.
- Prefer a tool's own cleanup command when it works. Delete directly only where the native command is known to fail.
- Report measured free-space change, not `du` totals, as the result.
- Never run `arin clean --yes` or click Clean on a developer machine as part of testing. Use the tests' sandbox for destructive paths.
- The `.app` bundle ships a binary named `Arin`, and the CLI is `arin`. Keep the SwiftPM product names distinct (`ArinApp`, `arin`) because the filesystem is case-insensitive.
