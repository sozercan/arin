# 0006: Keep app, CLI, and release boundaries explicit

**Status:** Accepted

## Context

The GUI and CLI share Swift code and state, but SwiftPM does not produce the complete installed app. macOS packaging and SwiftUI hosting add boundaries that are not obvious from the target or view declarations.

## Decision

- Build the `ArinApp` and `arin` products separately and stage each thin binary before the next architecture build: SwiftPM can reuse the products directory and only build the last of several `--product` flags. Put the installed CLI in `Contents/Helpers` so it cannot collide with `Arin` on case-insensitive volumes. Compile the Icon Composer package with `actool` for `Assets.car` and Finder's `.icns`; do not copy it as a SwiftPM resource. Give debug builds their own bundle ID and state so their Auto settings, project roots, and review preferences cannot affect the installed app. Make the bare executable from `swift run` a regular app before opening windows.
- Sign the helper before the app that seals it. For notarization, sign both with hardened runtime and a secure timestamp. When importing the signing identity, restrict private-key access and put the temporary keychain first for lookup. Fetch full release history for notes. Only tag pushes publish; manual dispatch is for validation. See [release operations](../releasing.md) for signing fallback and cask prerequisites.
- Pass the app model explicitly to lazily hosted table cells and the separately hosted status bar; relying on environment inheritance in the table crashed during scrolling. Use the system safe-area bar for its scroll-edge treatment and keep it out of the inspector. Focus in the table controls inspection, while checkboxes govern cleaning. For bulk toggles, only rows that can be switched on should decide whether the group turns on or off. Keep the map independent of the table's search filter. Preserve the former default sort direction when loading preferences that did not save a direction.
- App bundle sizes can take minutes to enumerate. Publish the list with cask information first, fill sizes as they finish, and discard cancelled results when reloading. Snapshot the uninstall selection before the sheet clears it, then rebuild the catalog used for matching, rather than depending on the displayed list. Preserve the user's selection changes made while an agent review runs; cleaning, unlike a scan or review, runs to completion.
- The app starts with a restricted `PATH`, so explicitly include developer tool locations. Ignore macOS developer-tool stubs until a real developer directory is available, to avoid prompting for an install during a scan. Pass subprocess cancellation through from the caller and use file-backed output so a full pipe cannot stall a verbose tool.
- The main screen is an inbox. Each candidate lands in exactly one mailbox, derived from its effective risk and the current level: Kept for keep, Safe to Clean when it would be selected by default, Needs a Look otherwise. Changing the level or getting an agent verdict moves items without separate state. Cleaning from the inbox confirms and cleans only the items it names, through the same confirm sheet, never the checkbox selection, which still drives All Items and the toolbar. Read state lasts for one scan.
- History stacks the largest items by their peak size across the shown scans, so items cleaned recently still get their own layer, and measures regrowth from the first scan after the latest cleanup. With no cleanup inside the last 60 scans it measures from the oldest of them, so regrowth is a rolling window rather than a lifetime total; each row names its start date. The menu bar icon is a tank of the top 100 GB of the disk (or four times the alert threshold, if larger) with ticks at the alert level, because on most developer Macs a whole-disk gauge is too full to show a change.
- Use a squarified treemap to keep proportional tiles legible, a stable color per category, and a legend when small tiles lack labels. Keep the menu text-only and visually separate the Clean action from scan-wide controls in the toolbar.

## Consequences

Packaging needs its own verification beyond `swift build`. Test cleanup only through sandboxed paths, not a developer's real Home or a packaged app's Clean button.
