/// Cross-process conventions shared by the driver (C++), Host, and App.
///
/// The driver uses the notification and path literals directly in
/// `packages/driver/src/Plugin.cpp`; those must stay in sync with the values
/// here.
public enum MonivolNotifications {

    /// Host -> driver: the control file content changed.
    /// Driver side: `Plugin.cpp` listens for this Darwin notification.
    public static let devicesChanged = "com.monivol.devices-changed"

    /// Host -> App: device-state.json was rewritten.
    public static let deviceStateChanged = "com.monivol.device-state-changed"

    /// App -> Host: request to bounce (reconnect) the audio device.
    public static let bounceRequest = "com.monivol.bounce-request"
}

public enum MonivolPaths {

    /// Driver control file: Host writes it and posts `devicesChanged`; the
    /// driver also polls it as a fallback.
    /// Host side: `MoniVolConfig.controlFilePath` / `PathManager.controlFilePath`.
    /// Driver side: `Plugin.cpp` reads this literal directly.
    public static let controlFile = "/tmp/monivol-devices.txt"

    /// Shared memory file prefix: `/tmp/monivol-<sanitized-uid>`.
    public static let sharedMemoryPrefix = "/tmp/monivol-"

    /// Application Support subdirectory for IPC files (device-state.json).
    public static let appSupportFolder = "MoniVol"
}
