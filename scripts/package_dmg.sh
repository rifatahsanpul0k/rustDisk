#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/dist/RustDisk.app"
ICNS_FILE="$ROOT_DIR/dist/AppIcon.icns"
DMG_STAGING="$ROOT_DIR/dist/dmg_staging"
DMG_OUTPUT="$ROOT_DIR/dist/RustDisk-macos-arm64.dmg"
VOL_NAME="RustDisk Installer"

# Never reuse a bundle from an earlier run: the DMG must contain exactly what the
# current sources build to.
echo "==> Removing any previous app bundle..."
rm -rf "$APP_BUNDLE"

echo "==> Building a fresh release app bundle..."
"$ROOT_DIR/scripts/package_release_app.sh"

if [[ ! -d "$APP_BUNDLE" ]]; then
    printf '%s\n' "error: package_release_app.sh did not produce $APP_BUNDLE" >&2
    exit 1
fi

if [[ ! -f "$ICNS_FILE" ]]; then
    "$ROOT_DIR/scripts/generate_app_icon.sh"
fi

echo "==> Embedding AppIcon.icns into RustDisk.app..."
mkdir -p "$APP_BUNDLE/Contents/Resources"
cp "$ICNS_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

PLIST="$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
plutil -lint "$PLIST"
touch "$APP_BUNDLE"

echo "==> Ad-hoc codesigning RustDisk.app..."
codesign --force --deep --sign - "$APP_BUNDLE"
codesign --verify --verbose=2 "$APP_BUNDLE"

echo "==> Staging drag-and-drop DMG layout..."
rm -rf "$DMG_STAGING" "$DMG_OUTPUT" "${DMG_OUTPUT}.sha256"
mkdir -p "$DMG_STAGING"

cp -R "$APP_BUNDLE" "$DMG_STAGING/RustDisk.app"
ln -s /Applications "$DMG_STAGING/Applications"
cp "$ICNS_FILE" "$DMG_STAGING/.VolumeIcon.icns"

if command -v SetFile >/dev/null 2>&1; then
    SetFile -a C "$DMG_STAGING" || true
fi

echo "==> Building compressed DMG installer..."
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_OUTPUT"

rm -rf "$DMG_STAGING"

echo "==> Ad-hoc codesigning DMG..."
codesign --force --sign - "$DMG_OUTPUT"
# Record the bare file name, not the build machine's absolute path, so that
# `shasum -a 256 -c RustDisk-macos-arm64.dmg.sha256` works wherever it is downloaded.
(
    cd "$(dirname "$DMG_OUTPUT")"
    shasum -a 256 "$(basename "$DMG_OUTPUT")" | tee "$(basename "$DMG_OUTPUT").sha256"
)

echo "==> Done! Release installer ready at: $DMG_OUTPUT"
