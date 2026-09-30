# MoniVol App

`MoniVolApp` is the macOS menu bar interface for external display volume control. It provides a volume slider, mute toggle, device selection, onboarding, driver installation, login launch setting, and Sparkle updates. EQ controls have been removed.

The App starts `MoniVolHost` when needed. Built-in and Bluetooth output devices remain native; the Host creates virtual devices only for eligible HDMI/DisplayPort displays.

The active output card and device list share SF Symbols icon rules. AirPods, AirPods Pro, and AirPods Max are identified by name. Other headphones are identified by CoreAudio output-stream terminal type, supplemented by common headphone name keywords. Unrecognized outputs use the external-speaker icon. Renamed devices without identifiable terminal metadata may use this fallback; no additional icon assets are bundled.

Device discovery and binding update UI state on the main thread. Opening the popover refreshes the current output, and selecting a device refreshes its binding immediately. Proxy identity is determined by the `-monivol` UID suffix. Popover closure removes the global event monitor, and repeated monitor starts do not register duplicate handlers.

## Build

```bash
cd apps/mac/MoniVolApp
swift build -c release
```

For a complete app bundle, run `make build` from the repository root. macOS 13 or newer, Xcode Command Line Tools, CMake, and the libASPL submodule are required.
