# MoniVol HAL Driver

A CoreAudio HAL (Hardware Abstraction Layer) plugin for macOS that creates virtual proxy output devices. When an app sends audio to a proxy device, the driver writes it into shared memory. The host process reads from shared memory and renders to the real hardware device.

The driver runs inside `coreaudiod` (not as a standalone process). When installed at `/Library/Audio/Plug-Ins/HAL/MoniVolDriver.driver`, macOS loads it as a system audio plugin.

## How it works

```
Application audio
    |
    v
+--------------------------+
| macOS CoreAudio (HAL)    |
| routes output to proxy   |
+-----------+--------------+
            |
            v
+--------------------------+
| MoniVolDriver          |
| (this plugin)            |
|                          |
| OnWriteMixedOutput()     |
| - format conversion      |
| - sample rate conversion |
| - ring buffer write      |
+-----------+--------------+
            | shared memory (mmap)
            | /tmp/monivol-<uid>
            v
+--------------------------+
| MoniVolHost            |
| - ring buffer read       |
| - hardware output        |
+--------------------------+
```

## Files

| File | Purpose |
|---|---|
| `src/Plugin.cpp` | Driver runtime logic: plugin factory, device creation/removal, IO handling, health checks |
| `include/RFSharedAudio.h` | Shared memory protocol and ring buffer helpers |
| `CMakeLists.txt` | Build config for `MoniVolDriver.driver` |
| `Info.plist` | Bundle metadata, factory UUID, bundle identifier (`com.monivol.driver`) |
| `install.sh` | Installs `build/MoniVolDriver.driver` to `/Library/Audio/Plug-Ins/HAL/` |
| `uninstall.sh` | Removes the installed driver bundle |
| `VERSION` | Driver version source; `tools/update_versions.sh` synchronizes it from the latest Git tag before a release build |
| `vendor/libASPL/` | Third-party C++ wrapper around CoreAudio HAL plugin APIs |

`include/RFSharedAudio.h` is intentionally kept in sync with:
`packages/host/Sources/CMoniVolAudio/include/RFSharedAudio.h`

The driver is C++ and cannot import `MoniVolCore`. Its `-monivol` UID suffix,
`/tmp/monivol-devices.txt` path, shared-memory prefix, and Darwin notification
name must stay synchronized with `packages/core/Sources/MoniVolCore/`.

## Entry point

```cpp
extern "C" void* MoniVolDriverPluginFactory(CFAllocatorRef allocator, CFUUIDRef typeUUID)
```

If `typeUUID` matches `kAudioServerPlugInTypeUUID`, this function lazily creates global driver state and returns the plugin reference. The factory UUID is `B3F04000-8F04-4F84-A72E-B2D4F8E6F1DA` (declared in `Info.plist`).

## Device lifecycle

The driver does not hardcode proxy devices. It reconciles desired devices from a host-written control file.

### Control file: `/tmp/monivol-devices.txt`

Format per line:

```
DeviceName|DeviceUID
```

`MonitorControlFile()` listens for the `com.monivol.devices-changed` Darwin notification so host updates can be applied immediately. It also calls `SyncDevices()` every ~1 second as a fallback.

`SyncDevices()` behavior:

- Add proxy device when UID exists in the control file and its host heartbeat is fresh.
- Remove proxy device when UID is no longer desired (missing from file or heartbeat stale).
- Clear cached heartbeat state after a UID disappears so reconnecting hardware starts with fresh liveness state.

### Proxy device creation

`CreateProxyDevice()` creates one output-only proxy device with:

- Name: `"<OriginalName> (MoniVol)"`
- UID: `"<OriginalUID>-monivol"`
- Manufacturer: `"MoniVol"`
- Default format: 48 kHz, 2 channels
- Mixing enabled
- One output stream with custom volume and mute controls attached to it
- IO/control callbacks handled by `UniversalAudioHandler`

## Audio path

### OnStartIO

When the first client starts IO, the handler:

1. Opens `/tmp/monivol-<sanitized-uid>`
2. Maps shared memory with `PROT_READ | PROT_WRITE` and `MAP_SHARED`
3. Validates protocol version, sample rate, and channel count
4. Sets `driver_connected = 1`
5. Pre-allocates conversion, resampling, and silence buffers used by the realtime callback
6. Prefills half the ring with silence to reduce cold-start underruns
7. Retries up to 15 times with exponential backoff (30ms base, capped growth) if connection is not ready
8. Publishes the current proxy volume and mute state through shared memory

IO clients are reference-counted; `OnStopIO` disconnects shared memory when the last client stops.

### OnWriteMixedOutput

This callback runs on the audio IO thread for each buffer. It:

1. Updates `driver_heartbeat` and `driver_connected` via `rf_update_driver_heartbeat()`
2. Reads current stream `AudioStreamBasicDescription`
3. Rebuilds conversion/resampler state on format changes (sample rate/channel count)
4. Converts input to interleaved float32
5. Compensates timestamp gaps/overlaps by prepending silence or skipping frames
6. Applies linear-interpolation sample-rate conversion when needed
7. Applies adaptive drift compensation around target ring fill
8. Writes frames with `rf_ring_write()`

Implemented input conversion paths in `ConvertToFloat32Interleaved()`:

- Float32 (interleaved and non-interleaved)
- Signed Int16
- Signed Int24 (packed 3-byte)
- Signed Int32

## Shared memory layout (`RFSharedAudio`)

Defined in `include/RFSharedAudio.h`.
In this build, `sizeof(RFSharedAudio)` is 264 bytes, and `audio_data[]` begins at offset 264.

### Header fields

| Offset | Field | Type | Description |
|---|---|---|---|
| 0 | `protocol_version` | `uint32_t` | `0x00020000` |
| 4 | `header_size` | `uint32_t` | `sizeof(RFSharedAudio)` |
| 8 | `sample_rate` | `uint32_t` | 44100, 48000, 88200, 96000, 176400, 192000 |
| 12 | `channels` | `uint32_t` | 1-8 |
| 16 | `format` | `uint32_t` | `RFAudioFormat` enum |
| 20 | `bytes_per_sample` | `uint32_t` | Derived from format |
| 24 | `bytes_per_frame` | `uint32_t` | `bytes_per_sample * channels` |
| 28 | `ring_capacity_frames` | `uint32_t` | `sample_rate * duration_ms / 1000` |
| 32 | `ring_duration_ms` | `uint32_t` | Default 100 (allowed 20-100) |
| 36 | `driver_capabilities` | `uint32_t` | `RF_CAP_*` bitmask |
| 40 | `host_capabilities` | `uint32_t` | `RF_CAP_*` bitmask |
| 48 | `creation_timestamp` | `uint64_t` | Unix epoch seconds |
| 56 | `format_change_counter` | `atomic uint64_t` | Format-change counter |
| 64 | `write_index` | `atomic uint64_t` | Producer frame index |
| 72 | `read_index` | `atomic uint64_t` | Consumer frame index |
| 80 | `total_frames_written` | `atomic uint64_t` | Cumulative writes |
| 88 | `total_frames_read` | `atomic uint64_t` | Cumulative reads |
| 96 | `overrun_count` | `atomic uint64_t` | Overflow events |
| 104 | `underrun_count` | `atomic uint64_t` | Underrun events |
| 112 | `format_mismatch_count` | `atomic uint64_t` | Negotiation failures |
| 120 | `driver_connected` | `atomic uint32_t` | Driver connection flag |
| 124 | `host_connected` | `atomic uint32_t` | Host connection flag |
| 128 | `driver_heartbeat` | `atomic uint64_t` | Driver heartbeat |
| 136 | `host_heartbeat` | `atomic uint64_t` | Host heartbeat |
| 144 | `volume_scalar` | `atomic float` | Proxy volume, from 0.0 to 1.0 |
| 148 | `mute_state` | `atomic int32_t` | Proxy mute state |
| 152 | `eq_sequence` | `atomic uint32_t` | Sequence lock protecting the EQ snapshot |
| 156-203 | `eq_snapshot` | `RFEQSnapshot` | Ten EQ bands, preamp, and bypass state |
| 204-263 | `_reserved` | `uint8_t[60]` | Future expansion |
| 264+ | `audio_data[]` | `uint8_t[]` | `ring_capacity_frames * bytes_per_frame` bytes |

### Total mapped size

```
sizeof(RFSharedAudio) + (ring_capacity_frames * channels * bytes_per_sample)
```

Example at 48 kHz, 2 channels, float32, 100 ms (in this build):
`264 + (4800 * 2 * 4) = 38664` bytes.

### Ring buffer behavior

Single producer (driver) and single consumer (host), with monotonically increasing 64-bit indices.

- Overflow (`used + write > capacity`): write only the remaining free frames, drop the excess new frames, and increment `overrun_count`
- Underrun on host read: host emits silence and increments `underrun_count`

`rf_ring_write()` accepts float32 input and stores samples in negotiated shared format. `rf_ring_read()` outputs float32 for host-side processing.

## Health monitoring

Current liveness checks are applied during proxy-device sync, triggered by Darwin notifications and the fallback polling loop. Filesystem and recovery work stays out of the realtime audio callback:

- `HostHeartbeatFresh()` maps `/tmp/monivol-<uid>` read-only, tracks `host_heartbeat` changes, and treats heartbeat as stale after 15 seconds with no change.
- `SyncDevices()` only keeps/adds devices with fresh heartbeat state; stale entries are skipped and existing stale devices are removed.

`UniversalAudioHandler` also includes `IsHealthy()` and `AttemptRecovery()` helpers for shared-memory/file/ring validation, but they are not currently called from `OnWriteMixedOutput()`.

## Heartbeat protocol

- Driver calls `rf_update_driver_heartbeat()` on each `OnWriteMixedOutput` callback.
- Host calls `rf_update_host_heartbeat()` on a timer (`DispatchSourceTimer` in host code, default 1s interval).

A host heartbeat with no observed change for 15 seconds is treated as stale by `HostHeartbeatFresh()`.

## Building

Requirements:

- macOS (HAL driver target)
- CMake >= 3.20
- C++17 toolchain

```sh
cd packages/driver
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Output bundle: `build/MoniVolDriver.driver`

Debug build (AddressSanitizer enabled by project flags):

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build
```

## Installing

```sh
cd packages/driver
./install.sh
sudo killall coreaudiod
```

Notes:

- `install.sh` expects `./build/MoniVolDriver.driver` to exist.
- Script prompts for admin rights (`sudo`) internally for copy/ownership changes.
- Install target: `/Library/Audio/Plug-Ins/HAL/MoniVolDriver.driver`
- Restarting `coreaudiod` is required for load/unload and interrupts audio briefly.

## Uninstalling

```sh
cd packages/driver
./uninstall.sh
sudo killall coreaudiod
```

## Logging

- `os_log` subsystem: `com.monivol.driver`
- Fallback file log: `/tmp/monivol-driver-debug.log`

Example unified log query:

```sh
log show --predicate 'subsystem == "com.monivol.driver"' --last 5m
```

## Troubleshooting

| Symptom | Check |
|---|---|
| No proxy devices appear | Confirm host is running and `/tmp/monivol-devices.txt` exists |
| `OnStartIO` fails after retries | Confirm shared memory files exist: `ls /tmp/monivol-*` |
| Audio dropouts | Inspect overrun/underrun stats in logs |
| Driver not loading | Verify install path and restart `coreaudiod` |
| Stale proxy devices | Remove stale `/tmp/monivol-devices.txt` entry source and restart host/`coreaudiod` |

## Constants

| Constant | Value |
|---|---|
| `DEFAULT_SAMPLE_RATE` | 48000 |
| `DEFAULT_CHANNELS` | 2 |
| `HEALTH_CHECK_INTERVAL_SEC` | 3 (defined; helper currently not invoked from callback loop) |
| `HEARTBEAT_INTERVAL_SEC` | 1 (defined; driver heartbeat is currently callback-driven) |
| `HEARTBEAT_TIMEOUT_SEC` | 15 |
| `RF_MAX_CHANNELS` | 8 |
| `RF_RING_DURATION_MS_DEFAULT` | 100 |
| `RF_AUDIO_PROTOCOL_VERSION` | `0x00020000` |
