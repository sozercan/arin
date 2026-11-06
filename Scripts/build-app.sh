#!/usr/bin/env bash
# Builds build/Arin.app (ad-hoc signed) from the SwiftPM ArinApp and arin products.
# Usage: Scripts/build-app.sh [debug|release]
#   ARCHES="arm64 x86_64"  build a universal binary (default: host architecture)
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

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
install_product ArinApp "$APP/Contents/MacOS/Arin"
install_product arin "$APP/Contents/Resources/arin"
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

codesign --force --sign - --timestamp=none "$APP/Contents/Resources/arin"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP ($BUNDLE_ID $MARKETING_VERSION ($BUILD_NUMBER), ${ARCH_LIST[*]})"
