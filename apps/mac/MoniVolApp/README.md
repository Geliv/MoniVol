# MoniVol App

`MoniVolApp` is the macOS menu bar interface for external display volume control. It provides a volume slider, mute toggle, device selection, onboarding, driver installation, login launch setting, and Sparkle updates. EQ controls have been removed.

The App starts `MoniVolHost` when needed. Built-in and Bluetooth output devices remain native; the Host creates virtual devices only for eligible HDMI/DisplayPort displays.

## Build

```bash
cd apps/mac/MoniVolApp
swift build -c release
```

For a complete app bundle, run `make build` from the repository root. macOS 13 or newer, Xcode Command Line Tools, CMake, and the libASPL submodule are required.
