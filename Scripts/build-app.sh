#!/usr/bin/env bash
# Builds build/Arin.app (ad-hoc signed) from the SwiftPM ArinApp product.
# Usage: Scripts/build-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Arin.app"
VERSION="${ARIN_VERSION:-0.1.0}"

cd "$ROOT"
# One --product per invocation: SwiftPM only builds the last one when several are given.
swift build -c "$CONFIG" --product ArinApp
swift build -c "$CONFIG" --product arin
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ArinApp" "$APP/Contents/MacOS/Arin"
cp "$BIN/arin" "$APP/Contents/Resources/arin"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Arin</string>
  <key>CFBundleDisplayName</key><string>Arin</string>
  <key>CFBundleIdentifier</key><string>com.sertacozercan.Arin</string>
  <key>CFBundleExecutable</key><string>Arin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Sertac Ozercan</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP/Contents/Resources/arin"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"
