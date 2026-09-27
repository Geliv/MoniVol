#!/bin/bash
# Uninstall MoniVol driver (for testing)

echo "  Uninstalling MoniVol driver..."

osascript -e 'do shell script "rm -rf /Library/Audio/Plug-Ins/HAL/MoniVolDriver.driver /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver && killall coreaudiod" with administrator privileges'

if [ $? -eq 0 ]; then
    echo "OK: Driver uninstalled successfully"
    echo "OK: Audio system restarted"
else
    echo "ERROR: Failed to uninstall driver"
    exit 1
fi

echo ""
echo "Driver removed. Audio system will restart momentarily."
