#!/bin/bash
# Update component versions
# Usage:
#   ./tools/update_versions.sh [version] [--app-only|--driver-only|--host-only]
#   If version not provided, extracts from latest git tag (v1.0.5 -> 1.0.5)
#   Without flags, updates all components

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Parse arguments
VERSION=""
UPDATE_APP=true
UPDATE_DRIVER=true
UPDATE_HOST=true

for arg in "$@"; do
    case $arg in
        --app-only)
            UPDATE_DRIVER=false
            UPDATE_HOST=false
            ;;
        --driver-only)
            UPDATE_APP=false
            UPDATE_HOST=false
            ;;
        --host-only)
            UPDATE_APP=false
            UPDATE_DRIVER=false
            ;;
        *)
            if [ -z "$VERSION" ]; then
                VERSION="$arg"
            fi
            ;;
    esac
done

# Determine version if not provided
if [ -z "$VERSION" ]; then
    # Get latest tag
    GIT_TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "v1.0.0")
    VERSION="${GIT_TAG#v}"  # Remove 'v' prefix
fi

echo "INFO: Updating component versions to: $VERSION"
echo ""

# Update MoniVolApp Info.plist
if [ "$UPDATE_APP" = true ]; then
    APP_PLIST="$PROJECT_ROOT/apps/mac/MoniVolApp/Info.plist"
    if [ -f "$APP_PLIST" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PLIST" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP_PLIST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_PLIST" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$APP_PLIST"
        echo "OK: Updated apps/mac/MoniVolApp/Info.plist"
    else
        echo "WARN: $APP_PLIST not found"
    fi
fi

# Update MoniVolDriver Info.plist and VERSION file
if [ "$UPDATE_DRIVER" = true ]; then
    DRIVER_PLIST="$PROJECT_ROOT/packages/driver/Info.plist"
    if [ -f "$DRIVER_PLIST" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$DRIVER_PLIST" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$DRIVER_PLIST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$DRIVER_PLIST" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$DRIVER_PLIST"
        echo "OK: Updated packages/driver/Info.plist"

        # Update VERSION file
        echo "$VERSION" > "$PROJECT_ROOT/packages/driver/VERSION"
        echo "OK: Updated packages/driver/VERSION"
    else
        echo "WARN: $DRIVER_PLIST not found"
    fi
fi

# Update MoniVolHost Info.plist
if [ "$UPDATE_HOST" = true ]; then
    HOST_PLIST="$PROJECT_ROOT/packages/host/Info.plist"
    if [ -f "$HOST_PLIST" ]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$HOST_PLIST" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$HOST_PLIST"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$HOST_PLIST" 2>/dev/null || \
            /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $VERSION" "$HOST_PLIST"
        echo "OK: Updated packages/host/Info.plist"
    else
        echo "WARN: $HOST_PLIST not found (will be created next)"
    fi
fi

# Update driver CMakeLists.txt version
if [ "$UPDATE_DRIVER" = true ]; then
    DRIVER_CMAKE="$PROJECT_ROOT/packages/driver/CMakeLists.txt"
    if [ -f "$DRIVER_CMAKE" ]; then
        # CMake only accepts numeric versions (major.minor.patch) - strip any suffix like "-internal"
        CMAKE_VERSION=$(echo "$VERSION" | sed 's/-.*//')
        # Use sed to replace the version in project() line
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/project(MoniVolDriver VERSION [0-9][0-9.]*/project(MoniVolDriver VERSION $CMAKE_VERSION/" "$DRIVER_CMAKE"
        else
            sed -i "s/project(MoniVolDriver VERSION [0-9][0-9.]*/project(MoniVolDriver VERSION $CMAKE_VERSION/" "$DRIVER_CMAKE"
        fi
        echo "OK: Updated packages/driver/CMakeLists.txt"
    else
        echo "WARN: $DRIVER_CMAKE not found"
    fi
fi

echo ""
echo "OK: Version update complete"
echo ""
echo "Updated components:"
if [ "$UPDATE_APP" = true ]; then
    echo "  - App: $VERSION (apps/mac/MoniVolApp/Info.plist)"
fi
if [ "$UPDATE_DRIVER" = true ]; then
    echo "  - Driver: $VERSION (packages/driver/Info.plist, CMakeLists.txt, VERSION)"
fi
if [ "$UPDATE_HOST" = true ]; then
    echo "  - Host: $VERSION (packages/host/Info.plist)"
fi
