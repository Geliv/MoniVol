#!/bin/bash
# MoniVol HAL Driver Installation Script

set -e

DRIVER_PATH="./build/MoniVolDriver.driver"
INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/MoniVolDriver.driver"
LEGACY_INSTALL_PATH="/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"

echo "MoniVol HAL Driver Installer"
echo "=============================="

# Check if driver was built
if [ ! -d "$DRIVER_PATH" ]; then
    echo "Error: Driver not found at $DRIVER_PATH"
    echo "Please build the driver first: cd build && cmake --build ."
    exit 1
fi

# Replace either generation of the driver before restarting Core Audio.
sudo killall SoundBridgeHost 2>/dev/null || true
sudo rm -rf "$INSTALL_PATH" "$LEGACY_INSTALL_PATH"

# Install driver
echo "Installing driver to $INSTALL_PATH..."
sudo cp -R "$DRIVER_PATH" "$INSTALL_PATH"
sudo chown -R root:wheel "$INSTALL_PATH"

echo ""
echo "Driver installed successfully!"
echo ""
echo "IMPORTANT: You must restart coreaudiod for changes to take effect:"
echo "  sudo killall coreaudiod"
echo ""
echo "WARNING: This will interrupt all audio playback (~2 seconds)."
echo "Make sure MoniVol is NOT selected as the default output device before restarting."
