import CoreAudio

/// CoreAudio device property queries shared by MoniVolApp and MoniVolHost.
///
/// This is the single source of truth for how a device property is read.
/// Both processes must agree on these semantics, so do not keep local copies.
public enum DeviceQuery {

    /// Human-readable device name via `kAudioDevicePropertyDeviceNameCFString`.
    public static func name(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &name) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfName = name?.takeUnretainedValue() else {
            return nil
        }
        return cfName as String
    }

    /// Persistent device UID via `kAudioDevicePropertyDeviceUID`.
    /// UIDs are the only stable identifier across device plug/unplug cycles;
    /// `AudioDeviceID` values are only valid for the current enumeration.
    public static func uid(_ deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        let status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfUID = uid?.takeUnretainedValue() else {
            return nil
        }
        return cfUID as String
    }

    /// Whether the device exposes at least one output stream.
    public static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Whether the device supports writable hardware volume control via
    /// `kAudioDevicePropertyVolumeScalar`.
    ///
    /// Strict semantics: the property must exist AND be settable, checked on
    /// the master element (0) and channel elements (1, 2) of the output scope.
    /// Both the proxy-creation decision (Host) and the volume-slider UI
    /// decision (App) use this same definition.
    public static func hasWritableVolumeControl(_ deviceID: AudioObjectID) -> Bool {
        let elements: [UInt32] = [
            kAudioObjectPropertyElementMain,  // element 0 (master)
            1,                                 // element 1 (left channel)
            2                                  // element 2 (right channel)
        ]

        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            var settable = DarwinBoolean(false)
            if AudioObjectHasProperty(deviceID, &address),
               AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
               settable.boolValue {
                return true
            }
        }

        return false
    }

    /// Find a device's `AudioObjectID` by its persistent UID.
    public static func findDeviceID(byUID targetUID: String) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return nil }

        for deviceID in deviceIDs {
            if let uid = Self.uid(deviceID), uid == targetUID {
                return deviceID
            }
        }
        return nil
    }

    /// Enumerate all device IDs currently present in the system.
    public static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs
    }
}
