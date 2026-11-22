#!/usr/bin/env bash
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Arin.app"
STAGE="$ROOT/build/arch-products"
cd "$ROOT"
source "$ROOT/version.env"

RELEASE_BUNDLE_ID="com.sertacozercan.Arin"
if [[ "$CONFIG" == "debug" ]]; then BUNDLE_ID="$RELEASE_BUNDLE_ID.debug"; else BUNDLE_ID="$RELEASE_BUNDLE_ID"; fi

read -r -a ARCH_LIST <<< "${ARCHES:-$(uname -m)}"

build_product() {
  local product="$1" arch bin
  for arch in "${ARCH_LIST[@]}"; do
    swift build -c "$CONFIG" --arch "$arch" --product "$product"
    bin="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"
    mkdir -p "$STAGE/$arch"
    cp "$bin/$product" "$STAGE/$arch/$product"
  done
}

install_product() {
  local product="$1" dest="$2" inputs=() arch
  for arch in "${ARCH_LIST[@]}"; do inputs+=("$STAGE/$arch/$product"); done
  if [[ ${#inputs[@]} -gt 1 ]]; then lipo -create "${inputs[@]}" -output "$dest"; else cp "${inputs[0]}" "$dest"; fi
  chmod +x "$dest"
}

rm -rf "$APP" "$STAGE"
build_product ArinApp
build_product arin

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
install_product ArinApp "$APP/Contents/MacOS/Arin"
install_product arin "$APP/Contents/Helpers/arin"
rm -rf "$STAGE"

xcrun actool --compile "$APP/Contents/Resources" \
  --app-icon AppIcon \
  --output-partial-info-plist "$ROOT/build/AppIconInfo.plist" \
  --platform macosx --target-device mac --minimum-deployment-target 26.0 \
  --errors --warnings --notices \
  "$ROOT/Sources/ArinApp/Resources/AppIcon.icon" >/dev/null
[[ -f "$APP/Contents/Resources/Assets.car" ]] || { echo "ERROR: actool did not produce Assets.car" >&2; exit 1; }
rm -f "$ROOT/build/AppIconInfo.plist"

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
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
    CODESIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
    ;;
  *)
    echo "ERROR: unknown ARIN_SIGNING '$SIGNING' (expected adhoc, dev, or developer-id)" >&2
    exit 1
    ;;
esac
codesign "${CODESIGN_ARGS[@]}" --identifier "$BUNDLE_ID.cli" "$APP/Contents/Helpers/arin"
codesign "${CODESIGN_ARGS[@]}" "$APP"
echo "Built $APP ($BUNDLE_ID $MARKETING_VERSION ($BUILD_NUMBER), ${ARCH_LIST[*]}, $SIGNING signing)"
