# Contributing to Arin

## Build and test

Requires macOS 26 and Xcode 26 or later. Arin has no third-party dependencies.

```bash
swift build
swift test
Scripts/build-app.sh          # builds build/Arin.app (ad-hoc signed)
Scripts/verify-app.sh         # checks the bundle: ID, binaries, signature, bundled CLI
open build/Arin.app
swift run arin scan           # read-only scan of this Mac
```

`ARCHES="arm64 x86_64" Scripts/build-app.sh` builds a universal app. The version comes from `version.env`. Debug builds use the bundle ID `com.sertacozercan.Arin.debug`, so they keep their own settings and never share them with an installed copy. CI runs the tests and packages a universal app for every change to code or scripts.

Never run `arin clean --yes`, or click Clean, on your own machine to test a change. The tests have a sandbox for destructive paths.

## How it's put together

- `Sources/ArinCore`: rules (`Rules/`, `Catalog.swift`), scanner, guardrails, executor, agent reviewer, and the keep list, history and plans (`Store.swift`, kept in `~/Library/Application Support/<bundle ID>`).
- `Sources/ArinApp`: the SwiftUI app (window, menu bar extra, settings).
- `Sources/arin-cli`: the `arin` command.
- `docs/learnings.md`: what real cleanups showed, and why each rule and guardrail exists.

## Changing rules

Read [docs/learnings.md](docs/learnings.md) first. Every rule should trace back to observed behavior.

- Actions come only from rules. Agent output is verdicts by candidate ID and never becomes a command or a path.
- `Guardrails.swift` is the last line of defense. Keep protected paths and the command allowlist strict, and add a test for any change.
- Prefer a tool's own cleanup command when it works. Delete directly only where the native command is known to fail.
- Report the measured change in free space, not `du` totals, as the result.

## Releasing

See [docs/releasing.md](docs/releasing.md).
