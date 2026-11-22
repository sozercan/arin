# Contributing to Arin

## Build and test

Requires macOS 26 and Xcode 26 or later. Arin has no third-party dependencies.

```bash
swift build
swift test
Scripts/check-comments.sh
Scripts/build-app.sh          # builds build/Arin.app (ad-hoc signed)
Scripts/verify-app.sh         # checks the bundle: ID, binaries, signature, bundled CLI
open build/Arin.app
swift run arin scan           # read-only scan of this Mac
```

`ARCHES="arm64 x86_64" Scripts/build-app.sh` builds a universal app. The version comes from `version.env`. Debug builds use the bundle ID `com.sertacozercan.Arin.debug`, so they keep their own settings and never share them with an installed copy. CI runs the tests and packages a universal app for every change to code or scripts.

Use `Scripts/build-app.sh [debug|release]` (defaults to `release`). To choose a signature, set `ARIN_SIGNING` to `adhoc`, `dev`, or `developer-id`; `APP_IDENTITY` optionally selects the matching keychain identity by hash or name. `Scripts/verify-app.sh` accepts `--bundle-id ID`, `--version X.Y.Z`, `--arches "arm64 x86_64"`, `--require-developer-id`, and an optional bundle path.

Never run `arin clean --yes`, or click Clean, on your own machine to test a change. The tests have a sandbox for destructive paths.

## How it's put together

- `Sources/ArinCore`: rules (`Rules/`, `Catalog.swift`), scanner, guardrails, executor, agent reviewer, and the keep list, history and plans (`Store.swift`, kept in `~/Library/Application Support/<bundle ID>`).
- `Sources/ArinApp`: the SwiftUI app (window, menu bar extra, settings).
- `Sources/arin-cli`: the `arin` command.
- `docs/learnings.md`: what real cleanups showed, and why each rule and guardrail exists.
- [`docs/adr/`](docs/adr/): accepted decisions and the constraints that motivated them.

## Comments and decisions

Do not add prose comments, doc comments, or section markers to code. Use names and tests for what the code does, an ADR for a non-obvious decision, and an issue for implementation debt. Use the repository's [`delete-comment` skill](.agents/skills/delete-comment/SKILL.md) for follow-up sweeps.

`Scripts/check-comments.sh --inventory` lists comments with file, line, column, and text. The checker uses Xcode's bundled Swift parser for Swift and checks comments in the repository's shell scripts, env files, YAML, workflow shell blocks, ignore file, and XML assets. Markdown, JSON, and generated or git-ignored files are not checked. The manifest's tools-version directive, script shebangs, and workflow versions on SHA-pinned actions are metadata, not prose.

The ratchet tracks legacy occurrences by repository path and exact comment text in `.comment-baseline.json`. When deleting a legacy comment, remove its count too. CI rejects new comments, stale allowances, and increases to the baseline compared with the base revision.

## Changing rules

Read [docs/learnings.md](docs/learnings.md) first. Every rule should trace back to observed behavior.

- Actions come only from rules. Agent output is verdicts by candidate ID and never becomes a command or a path.
- `Guardrails.swift` is the last line of defense. Keep protected paths and the command allowlist strict, and add a test for any change.
- Prefer a tool's own cleanup command when it works. Delete directly only where the native command is known to fail.
- Report the measured change in free space, not size estimates, as the result.

## Releasing

See [docs/releasing.md](docs/releasing.md).
