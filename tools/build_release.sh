#!/bin/bash
# Master build script for MoniVol release builds
# Builds all components as universal binaries (arm64 + x86_64)

set -euo pipefail  # Preserve Swift build failures through the log filter.

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Building MoniVol Release (Universal Binary)"
echo "==============================================="
echo ""

# Function to print section headers
section() {
    echo ""
    echo "----------------------------------------"
    echo "  $1"
    echo "----------------------------------------"
}

# Build a Swift package for both architectures and lipo into universal binary
build_swift_universal() {
    local PACKAGE_DIR="$1"
    local PRODUCT_NAME="$2"

    cd "$PACKAGE_DIR"

    echo "  Building arm64..."
    swift build -c release --triple arm64-apple-macosx 2>&1 | tail -1

    echo "  Building x86_64..."
    swift build -c release --triple x86_64-apple-macosx 2>&1 | tail -1

    local ARM64_BIN=".build/arm64-apple-macosx/release/$PRODUCT_NAME"
    local X86_BIN=".build/x86_64-apple-macosx/release/$PRODUCT_NAME"
    local UNIVERSAL_DIR=".build/universal/release"
    local UNIVERSAL_BIN="$UNIVERSAL_DIR/$PRODUCT_NAME"

    mkdir -p "$UNIVERSAL_DIR"
    lipo -create -output "$UNIVERSAL_BIN" "$ARM64_BIN" "$X86_BIN"

    echo "  Architectures: $(lipo -archs "$UNIVERSAL_BIN")"
}

# 1. Build HAL Driver (universal via CMAKE_OSX_ARCHITECTURES)
section "1/4 Building HAL Driver (C++ universal)"
cd "$PROJECT_ROOT/packages/driver"
mkdir -p build
cd build
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" ..
cmake --build . --config Release
echo "OK: HAL driver built (universal)"

# 2. Build Audio Host (universal via build-twice + lipo)
section "2/4 Building Audio Host (Swift universal)"
build_swift_universal "$PROJECT_ROOT/packages/host" "MoniVolHost"
echo "OK: Audio host built (universal)"

# 3. Build Menu Bar App (universal via build-twice + lipo)
section "3/4 Building Menu Bar App (Swift universal)"
build_swift_universal "$PROJECT_ROOT/apps/mac/MoniVolApp" "MoniVolApp"
echo "OK: Menu bar app built (universal)"

# 4. Create .app Bundle
section "4/4 Creating .app Bundle"
cd "$PROJECT_ROOT"
"$SCRIPT_DIR/create_app_bundle.sh"

echo ""
echo "----------------------------------------"
echo "  Build Complete! (Universal Binary)"
echo "----------------------------------------"
echo ""
echo "App bundle: $PROJECT_ROOT/dist/MoniVol.app"
echo ""
echo "Verify architectures:"
echo "  lipo -archs dist/MoniVol.app/Contents/MacOS/MoniVolApp"
echo "  lipo -archs dist/MoniVol.app/Contents/MacOS/MoniVolHost"
echo ""
echo "To test the app:"
echo "  open dist/MoniVol.app"
echo ""
echo "To create a DMG:"
echo "  tools/create_dmg.sh"
echo ""
