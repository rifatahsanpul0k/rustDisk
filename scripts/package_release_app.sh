#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/RustDisk.app"
ICNS_FILE="$ROOT_DIR/dist/AppIcon.icns"

"$ROOT_DIR/scripts/build_rust_bridge.sh"

swift build --package-path "$ROOT_DIR/macos-app" --configuration release --arch arm64
BIN_PATH="$(swift build --package-path "$ROOT_DIR/macos-app" --configuration release --arch arm64 --show-bin-path)"
EXECUTABLE="$BIN_PATH/RustDisk"
if [[ ! -x "$EXECUTABLE" ]]; then
    printf '%s\n' "SwiftPM did not produce the RustDisk executable: $EXECUTABLE" >&2
    exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/RustDisk"

verify_linked_libraries() {
    local binary="$1"
    local linked_paths
    local failed=0
    local library

    if ! linked_paths="$(otool -L "$binary" | tail -n +2 | awk '{ print $1 }')"; then
        printf '%s\n' "error: otool -L failed for $binary" >&2
        return 1
    fi
    if [[ -z "$linked_paths" ]]; then
        printf '%s\n' "error: otool -L reported no linked libraries for $binary" >&2
        return 1
    fi

    while IFS= read -r library; do
        case "$library" in
            */rust-core/target/*)
                printf '%s\n' "error: binary links to the Rust build directory: $library" >&2
                failed=1
                ;;
            /usr/lib/* | /System/Library/*)
                ;;
            *)
                printf '%s\n' "error: binary links to a non-system library: $library" >&2
                failed=1
                ;;
        esac
    done <<< "$linked_paths"

    return "$failed"
}

echo "==> Verifying RustDisk links only to system libraries..."
if ! verify_linked_libraries "$APP_DIR/Contents/MacOS/RustDisk"; then
    printf '%s\n' "error: $APP_DIR is not deployable; see otool -L output below." >&2
    otool -L "$APP_DIR/Contents/MacOS/RustDisk" >&2
    exit 1
fi

cp "$ROOT_DIR/macos-app/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

if [[ -d "$ROOT_DIR/macos-app/Resources" ]]; then
    cp -R "$ROOT_DIR/macos-app/Resources/." "$APP_DIR/Contents/Resources/"
fi

"$ROOT_DIR/scripts/generate_app_icon.sh"
cp "$ICNS_FILE" "$APP_DIR/Contents/Resources/AppIcon.icns"

PLIST="$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
plutil -lint "$PLIST"

echo "==> Ad-hoc codesigning RustDisk.app..."
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --verbose=2 "$APP_DIR"

printf '%s\n' "Packaged $APP_DIR"
