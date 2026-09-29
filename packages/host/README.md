# MoniVol Host

`MoniVolHost` creates virtual output devices only for connected HDMI/DisplayPort displays whose audio output has no writable volume control. Built-in speakers, Bluetooth headphones, and other native outputs are left alone.

For each eligible display, the Host publishes a control-file entry and a shared-memory ring buffer. The HAL driver creates the matching virtual device. When that virtual device is selected, the Host reads audio from shared memory, applies software volume and mute, and renders to the real display.

The Host remembers the last selected display UID. When that display disconnects, it stops forwarding and switches system output to the built-in device. When the same display reconnects, it waits for its virtual device to appear and selects it again. A deliberate selection of another native output clears the remembered display.

## Build

```bash
cd packages/host
swift build -c release
```

The Host uses CoreAudio, AudioToolbox, and the shared-memory C interface in `CMoniVolAudio`.
