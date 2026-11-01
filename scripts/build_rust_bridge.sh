#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="aarch64-apple-darwin"
RUST_DIR="$ROOT_DIR/rust-core"
GENERATED_DIR="$ROOT_DIR/macos-app/RustDisk/Generated"
FFI_DIR="$ROOT_DIR/macos-app/RustDiskCoreFFI"
LIB_DIR="$ROOT_DIR/macos-app/lib"
STATIC_LIB_NAME="librustdisk_core.a"
STATIC_LIB="$RUST_DIR/target/$TARGET/release/$STATIC_LIB_NAME"

# Keep in sync with `.macOS(...)` in macos-app/Package.swift. Without this, Rust
# and its C dependencies are built for the host OS version, and the linker warns
# that the static library targets a newer macOS than the app.
export MACOSX_DEPLOYMENT_TARGET="13.0"

if ! command -v cargo >/dev/null 2>&1; then
    printf '%s\n' "cargo is required to build RustDisk." >&2
    exit 1
fi

if ! rustup target list --installed | grep -Fxq "$TARGET"; then
    rustup target add "$TARGET"
fi

cargo build --manifest-path "$RUST_DIR/Cargo.toml" --release --target "$TARGET"

# The app links exclusively against the static library. The cdylib that Cargo
# also produces is never used: it would be recorded in the app binary as an
# absolute path into the build tree and could not be deployed.
if [[ ! -f "$STATIC_LIB" ]]; then
    printf '%s\n' "Expected static library was not built: $STATIC_LIB" >&2
    exit 1
fi

rm -rf "$GENERATED_DIR"
mkdir -p "$GENERATED_DIR"
mkdir -p "$FFI_DIR"

# UniFFI library mode reads its metadata from the static archive directly.
pushd "$RUST_DIR" >/dev/null
cargo run \
    --features uniffi/cli \
    --bin uniffi-bindgen \
    -- generate \
    --library "target/$TARGET/release/$STATIC_LIB_NAME" \
    --language swift \
    --out-dir "$GENERATED_DIR"
popd >/dev/null

cp "$GENERATED_DIR/rustdisk_coreFFI.h" "$FFI_DIR/rustdisk_coreFFI.h"

# Give SwiftPM a stable, project-local path to link against. Only the static
# archive is ever placed here, so a dynamic library can never be picked up.
rm -rf "$LIB_DIR"
mkdir -p "$LIB_DIR"
cp "$STATIC_LIB" "$LIB_DIR/$STATIC_LIB_NAME"

printf '%s\n' "Rust bridge generated in $GENERATED_DIR"
printf '%s\n' "Static library staged at $LIB_DIR/$STATIC_LIB_NAME"
