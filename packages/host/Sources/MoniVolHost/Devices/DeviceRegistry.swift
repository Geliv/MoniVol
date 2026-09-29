import Darwin
import Foundation
import os.log
import MoniVolCore

// notify_post is available via <notify.h> but not always visible in cross-compilation.
@_silgen_name("notify_post")
private func _notify_post(_ name: UnsafePointer<CChar>) -> UInt32

private let logger = Logger(subsystem: "com.monivol.host", category: "DeviceRegistry")

class DeviceRegistry {
    private(set) var devices: [PhysicalDevice] = []
    var activeDeviceUID: String?

    func update(_ newDevices: [PhysicalDevice]) {
        devices = newDevices
        writeControlFile()
        writeDeviceStateFile()
    }

    func find(uid: String) -> PhysicalDevice? {
        return devices.first { $0.uid == uid }
    }

    func findAdded(comparing old: [PhysicalDevice]) -> [PhysicalDevice] {
        return devices.filter { new in
            !old.contains { $0.uid == new.uid }
        }
    }

    func findRemoved(comparing old: [PhysicalDevice]) -> [PhysicalDevice] {
        return old.filter { old in
            !devices.contains { $0.uid == old.uid }
        }
    }

    func writeControlFile() {
        let content = devices.map { "\($0.name)|\($0.uid)" }.joined(separator: "\n")
        let filePath = MoniVolConfig.controlFilePath

        do {
            // 原子替换，避免驱动轮询时读到短暂不存在的控制文件。
            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
            _ = _notify_post(MonivolNotifications.devicesChanged)
        } catch {
            logger.error("Failed to write control file: \(error.localizedDescription)")
        }
    }

    /// Write device-state.json for the menu bar App IPC.
    /// Contains only device list and active device — no volume/mute state.
    func writeDeviceStateFile() {
        struct IPCDeviceInfo: Codable {
            let name: String
            let uid: String
            let isFixedVolume: Bool
        }

        struct IPCDeviceState: Codable {
            let devices: [IPCDeviceInfo]
            let activeDeviceUID: String?
        }

        let ipcDevices = devices.map {
            IPCDeviceInfo(name: $0.name, uid: $0.uid, isFixedVolume: $0.isFixedVolume)
        }
        let state = IPCDeviceState(devices: ipcDevices, activeDeviceUID: activeDeviceUID)

        do {
            let data = try JSONEncoder().encode(state)
            let fileURL = PathManager.appSupportDir.appendingPathComponent("device-state.json")
            let tmpURL = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmpURL, options: [.atomic])
            let fm = FileManager.default
            if fm.fileExists(atPath: fileURL.path) {
                try fm.removeItem(at: fileURL)
            }
            try fm.moveItem(at: tmpURL, to: fileURL)
            _ = _notify_post(MonivolNotifications.deviceStateChanged)
            logger.info("Wrote device-state.json (\(self.devices.count) devices)")
        } catch {
            logger.error("Failed to write device-state.json: \(error.localizedDescription)")
        }
    }
}
