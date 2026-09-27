import Darwin
import Foundation

// Darwin notify API — not always visible during x86_64 cross-compilation.
@_silgen_name("notify_register_dispatch")
private func _notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ out_token: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func _notify_cancel(_ token: Int32) -> UInt32

/// Device info transmitted via IPC (device-state.json).
/// Contains only device list and active device — no volume/mute state.
struct IPCDeviceInfo: Codable {
    let name: String
    let uid: String
    let isFixedVolume: Bool
}

struct IPCDeviceState: Codable {
    let devices: [IPCDeviceInfo]
    let activeDeviceUID: String?
}

/// Handles IPC with the Host process via `device-state.json`.
///
/// - Host writes this file only on device plug/unplug (low frequency).
/// - App monitors the file via DispatchSource for changes.
/// - Volume/mute state is NOT included — that flows through CoreAudio API.
class IPCController {
    static let shared = IPCController()

    private let fileURL: URL
    private var fileDescriptor: Int32 = -1
    private var dispatchSource: DispatchSourceFileSystemObject?
    private var darwinNotifyToken: Int32 = 0
    private var darwinNotifyRegistered = false
    var onDeviceStateChanged: ((IPCDeviceState) -> Void)?

    private init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("MoniVol")

        // Ensure directory exists
        try? FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true,
            attributes: nil
        )

        self.fileURL = appSupport.appendingPathComponent("device-state.json")
    }

    /// Start monitoring the device-state.json file for changes.
    func startMonitoring() {
        stopMonitoring()

        // Read initial state if file exists
        if let state = readDeviceState() {
            onDeviceStateChanged?(state)
        }

        // Register Darwin notification listener (primary notification mechanism)
        let status = _notify_register_dispatch(
            "com.monivol.device-state-changed",
            &darwinNotifyToken,
            DispatchQueue.main
        ) { [weak self] _ in
            guard let self else { return }
            if let state = self.readDeviceState() {
                self.onDeviceStateChanged?(state)
            }
        }

        if status == 0 /* NOTIFY_STATUS_OK */ {
            darwinNotifyRegistered = true
        } else {
            print("[IPCController] Darwin notification registration failed (status: \(status)), using file monitoring only")
        }

        // Keep existing DispatchSource file monitoring as fallback
        // Create file if it doesn't exist (so we can watch it)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        fileDescriptor = open(fileURL.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("[IPCController] Failed to open file for monitoring: \(fileURL.path)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            if let state = self.readDeviceState() {
                DispatchQueue.main.async {
                    self.onDeviceStateChanged?(state)
                }
            }

            // Re-open if file was deleted and recreated
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.stopMonitoring()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                    self.startMonitoring()
                }
            }
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
        }

        dispatchSource = source
        source.resume()
    }

    /// Stop monitoring the device-state file.
    func stopMonitoring() {
        // Cancel Darwin notification
        if darwinNotifyRegistered {
            _ = _notify_cancel(darwinNotifyToken)
            darwinNotifyRegistered = false
        }

        // Cancel DispatchSource
        dispatchSource?.cancel()
        dispatchSource = nil
    }

    /// Read and decode the current device state from disk.
    func readDeviceState() -> IPCDeviceState? {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              !data.isEmpty else {
            return nil
        }

        do {
            return try JSONDecoder().decode(IPCDeviceState.self, from: data)
        } catch {
            print("[IPCController] Failed to decode device-state.json: \(error)")
            return nil
        }
    }
}
