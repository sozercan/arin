#!/usr/bin/env bash
# Builds build/Arin.app from the SwiftPM ArinApp and arin products.
# Usage: Scripts/build-app.sh [debug|release]
#   ARCHES="arm64 x86_64"   build a universal binary (default: host architecture)
#   ARIN_SIGNING=adhoc      ad-hoc signature (default)
#   ARIN_SIGNING=dev        Apple Development identity, hardened runtime
#   ARIN_SIGNING=developer-id  Developer ID Application identity, hardened runtime, secure timestamp
#   APP_IDENTITY=<hash|name>   identity to use; otherwise the first matching one in the keychain
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Arin.app"
STAGE="$ROOT/build/arch-products"
cd "$ROOT"
source "$ROOT/version.env"

RELEASE_BUNDLE_ID="com.sertacozercan.Arin"
# Debug builds get their own bundle ID so they never share settings (Auto mode, agent,
# project folders) with an installed copy.
if [[ "$CONFIG" == "debug" ]]; then BUNDLE_ID="$RELEASE_BUNDLE_ID.debug"; else BUNDLE_ID="$RELEASE_BUNDLE_ID"; fi

read -r -a ARCH_LIST <<< "${ARCHES:-$(uname -m)}"

# Builds one product per architecture and stages each thin binary right away: some
# SwiftPM layouts reuse a single products folder for every --arch build.
build_product() {
  local product="$1" arch bin
  for arch in "${ARCH_LIST[@]}"; do
    # One --product per invocation: SwiftPM only builds the last one when several are given.
    swift build -c "$CONFIG" --arch "$arch" --product "$product"
    bin="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"
    mkdir -p "$STAGE/$arch"
    cp "$bin/$product" "$STAGE/$arch/$product"
  done
}

# Installs a product into the bundle, merging architectures with lipo when needed.
install_product() {
  local product="$1" dest="$2" inputs=() arch
  for arch in "${ARCH_LIST[@]}"; do inputs+=("$STAGE/$arch/$product"); done
  if [[ ${#inputs[@]} -gt 1 ]]; then lipo -create "${inputs[@]}" -output "$dest"; else cp "${inputs[0]}" "$dest"; fi
  chmod +x "$dest"
}

rm -rf "$APP" "$STAGE"
build_product ArinApp
build_product arin

# The CLI goes in Helpers: Contents/MacOS can't hold both Arin and arin on a case-insensitive
# volume, and Apple expects helper tools there rather than in Resources.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
install_product ArinApp "$APP/Contents/MacOS/Arin"
install_product arin "$APP/Contents/Helpers/arin"
rm -rf "$STAGE"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Arin</string>
  <key>CFBundleDisplayName</key><string>Arin</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Arin</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${MARKETING_VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Sertac Ozercan</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

SIGNING="${ARIN_SIGNING:-adhoc}"
find_identity() {
  security find-identity -v -p codesigning | awk -v kind="$1" '$0 ~ kind { print $2; exit }'
}
case "$SIGNING" in
  adhoc)
    CODESIGN_ARGS=(--force --sign - --timestamp=none)
    ;;
  dev)
    IDENTITY="${APP_IDENTITY:-$(find_identity "Apple Development")}"
    [[ -n "$IDENTITY" ]] || { echo "ERROR: no Apple Development identity found" >&2; exit 1; }
    CODESIGN_ARGS=(--force --options runtime --timestamp=none --sign "$IDENTITY")
    ;;
  developer-id)
    IDENTITY="${APP_IDENTITY:-$(find_identity "Developer ID Application")}"
    [[ -n "$IDENTITY" ]] || { echo "ERROR: no Developer ID Application identity found" >&2; exit 1; }
    # Notarization requires the hardened runtime and a secure timestamp on every binary.
    CODESIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
    ;;
  *)
    echo "ERROR: unknown ARIN_SIGNING '$SIGNING' (expected adhoc, dev, or developer-id)" >&2
    exit 1
    ;;
esac
# Innermost first: the helper, then the app that seals it.
codesign "${CODESIGN_ARGS[@]}" --identifier "$BUNDLE_ID.cli" "$APP/Contents/Helpers/arin"
codesign "${CODESIGN_ARGS[@]}" "$APP"
echo "Built $APP ($BUNDLE_ID $MARKETING_VERSION ($BUILD_NUMBER), ${ARCH_LIST[*]}, $SIGNING signing)"
