#!/bin/bash
# Create proper .app bundle structure for MoniVol
# Supports universal binaries (arm64 + x86_64)

set -e  # Exit on error

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="MoniVol.app"
APP_PATH="$DIST_DIR/$APP_NAME"

# Helper: find a Swift build product, checking universal build path first,
# then architecture-specific paths, then generic path.
find_swift_product() {
    local PACKAGE_DIR="$1"
    local PRODUCT_NAME="$2"

    # 1. Universal build path (lipo'd by build_release.sh)
    local UNIVERSAL="$PACKAGE_DIR/.build/universal/release/$PRODUCT_NAME"
    if [ -f "$UNIVERSAL" ] || [ -d "$UNIVERSAL" ]; then
        echo "$UNIVERSAL"
        return
    fi

    # 1b. Universal build path (swift build --arch arm64 --arch x86_64)
    local APPLE_UNIVERSAL="$PACKAGE_DIR/.build/apple/Products/Release/$PRODUCT_NAME"
    if [ -f "$APPLE_UNIVERSAL" ] || [ -d "$APPLE_UNIVERSAL" ]; then
        echo "$APPLE_UNIVERSAL"
        return
    fi

    # 2. Architecture-specific path (single-arch build)
    local ARCH=$(uname -m)
    local SWIFT_ARCH=""
    if [ "$ARCH" = "arm64" ]; then
        SWIFT_ARCH="arm64-apple-macosx"
    elif [ "$ARCH" = "x86_64" ]; then
        SWIFT_ARCH="x86_64-apple-macosx"
    fi
    if [ -n "$SWIFT_ARCH" ]; then
        local ARCH_PATH="$PACKAGE_DIR/.build/$SWIFT_ARCH/release/$PRODUCT_NAME"
        if [ -f "$ARCH_PATH" ] || [ -d "$ARCH_PATH" ]; then
            echo "$ARCH_PATH"
            return
        fi
    fi

    # 3. Generic path
    local GENERIC="$PACKAGE_DIR/.build/release/$PRODUCT_NAME"
    if [ -f "$GENERIC" ] || [ -d "$GENERIC" ]; then
        echo "$GENERIC"
        return
    fi

    # Not found
    echo ""
}

echo "Creating MoniVol.app bundle structure..."

# Clean and create dist directory
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Create .app bundle structure
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

echo "  Created bundle structure"

# Copy Info.plist
echo "  Copying Info.plist..."
cp "$PROJECT_ROOT/apps/mac/MoniVolApp/Info.plist" "$APP_PATH/Contents/Info.plist"
echo "  Info.plist copied"

# Copy app icon
echo "  Copying app icon..."
ICON_SOURCE="$PROJECT_ROOT/apps/mac/MoniVolApp/Sources/Resources/MyIcon.icns"
ICON_DEST="$APP_PATH/Contents/Resources/MyIcon.icns"
cp "$ICON_SOURCE" "$ICON_DEST"
echo "  App icon copied"

# Copy main executable (MoniVolApp)
echo "  Copying MoniVolApp executable..."
APP_EXECUTABLE=$(find_swift_product "$PROJECT_ROOT/apps/mac/MoniVolApp" "MoniVolApp")

if [ -z "$APP_EXECUTABLE" ]; then
    echo "  Error: MoniVolApp executable not found. Build it first:"
    echo "   cd apps/mac/MoniVolApp && swift build -c release --arch arm64 --arch x86_64"
    exit 1
fi

cp "$APP_EXECUTABLE" "$APP_PATH/Contents/MacOS/MoniVolApp"
chmod +x "$APP_PATH/Contents/MacOS/MoniVolApp"

echo "  MoniVolApp executable copied"

# Sparkle is a dynamic framework; SwiftPM does not embed it in the .app for us.
SPARKLE_FRAMEWORK="$PROJECT_ROOT/apps/mac/MoniVolApp/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "ERROR: Sparkle.framework not found. Resolve MoniVolApp's Swift package dependencies first."
    exit 1
fi
mkdir -p "$APP_PATH/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_PATH/Contents/Frameworks/Sparkle.framework"
echo "  Sparkle.framework copied"

# Copy MoniVolHost
echo "  Copying MoniVolHost..."
HOST_EXECUTABLE=$(find_swift_product "$PROJECT_ROOT/packages/host" "MoniVolHost")

if [ -z "$HOST_EXECUTABLE" ]; then
    echo "  Error: MoniVolHost executable not found. Build it first:"
    echo "   cd packages/host && swift build -c release --arch arm64 --arch x86_64"
    exit 1
fi

cp "$HOST_EXECUTABLE" "$APP_PATH/Contents/MacOS/MoniVolHost"
chmod +x "$APP_PATH/Contents/MacOS/MoniVolHost"
echo "  MoniVolHost copied"

# Copy MoniVolDriver.driver
echo "  Copying MoniVolDriver.driver..."
DRIVER_BUNDLE="$PROJECT_ROOT/packages/driver/build/MoniVolDriver.driver"

if [ ! -d "$DRIVER_BUNDLE" ]; then
    echo "  MoniVolDriver.driver not found - will need to be installed separately"
    echo "   Note: Driver installation will be handled during onboarding"
    echo "   For development, build with: cd packages/driver && ./install.sh"
else
    cp -R "$DRIVER_BUNDLE" "$APP_PATH/Contents/Resources/MoniVolDriver.driver"
    echo "  MoniVolDriver.driver copied"
fi

# Copy other app resources (images, fonts, etc.)
echo "  Copying app resources..."
RESOURCES_DIR="$PROJECT_ROOT/apps/mac/MoniVolApp/Sources/Resources"
if [ -d "$RESOURCES_DIR" ]; then
    # Presets belong to the retired EQ feature.
    rsync -av --exclude "Presets" "$RESOURCES_DIR"/ "$APP_PATH/Contents/Resources/" >/dev/null
    echo "  Resources copied"
else
    echo "  No resources directory found at $RESOURCES_DIR"
fi

# Create PkgInfo file
echo "APPL????" > "$APP_PATH/Contents/PkgInfo"

# Verify architectures if lipo is available
echo ""
echo "  MoniVol.app bundle created successfully!"
echo "   Location: $APP_PATH"
echo ""
if command -v lipo >/dev/null 2>&1; then
    echo "Architectures:"
    echo "  MoniVolApp: $(lipo -archs "$APP_PATH/Contents/MacOS/MoniVolApp" 2>/dev/null || echo 'unknown')"
    echo "  MoniVolHost: $(lipo -archs "$APP_PATH/Contents/MacOS/MoniVolHost" 2>/dev/null || echo 'unknown')"
    if [ -f "$APP_PATH/Contents/Resources/MoniVolDriver.driver/Contents/MacOS/MoniVolDriver" ]; then
        echo "  MoniVolDriver: $(lipo -archs "$APP_PATH/Contents/Resources/MoniVolDriver.driver/Contents/MacOS/MoniVolDriver" 2>/dev/null || echo 'unknown')"
    fi
    echo ""
fi
echo "Bundle contents:"
echo "  - MoniVolApp (main executable)"
echo "  - MoniVolHost (audio engine)"
echo "  - MoniVolDriver.driver (HAL driver)"
echo ""
echo "To test the bundle:"
echo "  open $APP_PATH"
echo ""
