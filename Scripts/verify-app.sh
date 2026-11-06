#!/usr/bin/env bash
# Checks a packaged Arin.app for the settings that are easy to break when building outside Xcode.
# Usage: Scripts/verify-app.sh [--bundle-id ID] [--version X.Y.Z] [--arches "arm64 x86_64"] [path/to/Arin.app]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Arin.app"
BUNDLE_ID="com.sertacozercan.Arin"
VERSION=""
ARCHES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --arches) ARCHES="$2"; shift 2 ;;
    -h|--help) sed -n 2,3p "$0"; exit 0 ;;
    *) APP="$1"; shift ;;
  esac
done

fail() { echo "ERROR: $*" >&2; exit 1; }
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$APP/Contents/Info.plist" 2>/dev/null || true; }

[[ -d "$APP" ]] || fail "app bundle not found: $APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist is invalid"

[[ "$(plist CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "CFBundleIdentifier is '$(plist CFBundleIdentifier)', expected $BUNDLE_ID"
[[ "$(plist CFBundleExecutable)" == "Arin" ]] || fail "CFBundleExecutable must be Arin"
[[ -x "$APP/Contents/MacOS/Arin" ]] || fail "app binary Contents/MacOS/Arin is missing"
[[ -x "$APP/Contents/Resources/arin" ]] || fail "bundled CLI Contents/Resources/arin is missing"
if [[ -n "$VERSION" ]]; then
  [[ "$(plist CFBundleShortVersionString)" == "$VERSION" ]] || fail "version is '$(plist CFBundleShortVersionString)', expected $VERSION"
fi

for arch in $ARCHES; do
  for binary in "$APP/Contents/MacOS/Arin" "$APP/Contents/Resources/arin"; do
    [[ " $(lipo -archs "$binary") " == *" $arch "* ]] || fail "$(basename "$binary") is missing $arch (has: $(lipo -archs "$binary"))"
  done
done

codesign --verify --deep --strict "$APP" || fail "code signature does not verify"
# The CLI must start; --help is read-only.
"$APP/Contents/Resources/arin" --help >/dev/null || fail "bundled CLI does not run"

echo "Verified $APP ($BUNDLE_ID $(plist CFBundleShortVersionString), $(lipo -archs "$APP/Contents/MacOS/Arin"))"
