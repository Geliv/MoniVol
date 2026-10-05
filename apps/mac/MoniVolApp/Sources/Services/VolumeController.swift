import Foundation
import CoreAudio
import Combine
import Darwin
import os.log
import MoniVolCore

// Darwin notify API — not always visible during x86_64 cross-compilation.
@_silgen_name("notify_post")
private func _notify_post(_ name: UnsafePointer<CChar>) -> UInt32

private let logger = Logger(subsystem: "com.monivol.app", category: "VolumeController")

/// Format an OSStatus as a FourCC string for readable CoreAudio error logging.
private func formatOSStatus(_ status: OSStatus) -> String {
    if status == noErr { return "noErr" }
    let chars: [Character] = [
        Character(UnicodeScalar(UInt8((status >> 24) & 0xFF))),
        Character(UnicodeScalar(UInt8((status >> 16) & 0xFF))),
        Character(UnicodeScalar(UInt8((status >> 8) & 0xFF))),
        Character(UnicodeScalar(UInt8(status & 0xFF)))
    ]
    let fourCC = String(chars)
    // If all printable ASCII, return as FourCC; otherwise return numeric
    if fourCC.allSatisfy({ $0.isASCII && !$0.isNewline }) {
        return "'\(fourCC)' (\(status))"
    }
    return "\(status)"
}

/// Represents an audio output device visible to the system.
struct OutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let isFixedVolume: Bool
    let isHeadphones: Bool

    static func == (lhs: OutputDevice, rhs: OutputDevice) -> Bool {
        lhs.uid == rhs.uid
    }
}

/// Bridges the menu bar UI with the Proxy Device's volume/mute properties
/// via CoreAudio HAL API. Zero file I/O for volume control.
class VolumeController: ObservableObject {
    static let shared = VolumeController()

    // MARK: - Published State

    @Published var activeDeviceName: String = ""
    @Published var activeDeviceUID: String = ""
    @Published var isFixedVolumeDevice: Bool = false
    @Published var currentVolume: Float = 0.35
    @Published var isMuted: Bool = false
    @Published var allDevices: [OutputDevice] = []

    // MARK: - Private

    private var proxyDeviceID: AudioObjectID = kAudioObjectUnknown
    private var physicalDeviceID: AudioObjectID = kAudioObjectUnknown
    private var listenedDeviceID: AudioObjectID = kAudioObjectUnknown

    // Block references for proper listener removal (P0 fix: prevents listener leak)
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private var hardwareListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultOutputListenerBlock: AudioObjectPropertyListenerBlock?
    private var serviceRestartListenerBlock: AudioObjectPropertyListenerBlock?
    /// 每次 coreaudiod 重启都会递增，旧的恢复重试据此失效。
    private var serviceRecoveryGeneration = 0
    private static let serviceRecoveryDelays: [TimeInterval] = [0.5, 1.0, 2.0, 4.0, 8.0]

    // Addresses stored as instance vars so start/stop use the same pointer
    private var volumeAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var muteAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute,
        mScope: kAudioObjectPropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    private var hardwareDevicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var serviceRestartedAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyServiceRestarted,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {
        refreshDeviceList()
        findAndBindProxyDevice()
        startHardwareListener()
        startServiceRestartListener()
    }

    // MARK: - Device Discovery

    /// Enumerate all output devices (excluding MoniVol proxies from the user-facing list,
    /// but including them internally for binding).
    func refreshDeviceList() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshDeviceList() }
            return
        }
        let deviceIDs = getAllOutputDeviceIDs()
        var devices: [OutputDevice] = []

        for deviceID in deviceIDs {
            guard let name = DeviceQuery.name(deviceID),
                  let uid = DeviceQuery.uid(deviceID) else { continue }

            // Skip MoniVol proxy devices in the user-facing device list
            if ProxyNaming.isProxyUID(uid) { continue }

            let isFixed = !DeviceQuery.hasWritableVolumeControl(deviceID)
            devices.append(OutputDevice(
                id: deviceID, name: name, uid: uid, isFixedVolume: isFixed,
                isHeadphones: DeviceQuery.isHeadphoneOutput(deviceID)
            ))
        }

        allDevices = devices
    }

    /// Find the active MoniVol proxy device and bind volume listeners.
    /// 返回绑定是否完整：默认输出可读，且需要监听的设备已成功注册音量监听。
    @discardableResult
    func findAndBindProxyDevice() -> Bool {
        // 设备绑定和 UI 状态统一在主线程更新，避免后台旧快照覆盖新设备状态。
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.findAndBindProxyDevice() }
            return false
        }
        stopListening()

        guard let defaultDeviceID = getDefaultOutputDevice(),
              let name = DeviceQuery.name(defaultDeviceID),
              let uid = DeviceQuery.uid(defaultDeviceID) else {
            // 默认输出暂时不可读（例如 coreaudiod 重启中）时清空旧绑定，避免继续使用失效的设备 ID。
            proxyDeviceID = kAudioObjectUnknown
            physicalDeviceID = kAudioObjectUnknown
            isFixedVolumeDevice = false
            return false
        }

        if let physicalUID = ProxyNaming.physicalUID(from: uid) {
            // Current default is a proxy device
            proxyDeviceID = defaultDeviceID
            physicalDeviceID = kAudioObjectUnknown

            // Extract physical device info from proxy UID
            let physicalName = name.replacingOccurrences(of: ProxyNaming.nameSuffix, with: "")

            activeDeviceName = physicalName
            activeDeviceUID = physicalUID
            isFixedVolumeDevice = true

            readCurrentVolume()
            readCurrentMute()
            startListening()
            return volumeListenerBlock != nil
        } else {
            // Current default is a physical device (no proxy)
            proxyDeviceID = kAudioObjectUnknown
            let hasVolume = DeviceQuery.hasWritableVolumeControl(defaultDeviceID)

            if hasVolume {
                physicalDeviceID = defaultDeviceID
            } else {
                physicalDeviceID = kAudioObjectUnknown
            }

            activeDeviceName = name
            activeDeviceUID = uid
            isFixedVolumeDevice = hasVolume

            if hasVolume {
                readCurrentVolume()
                readCurrentMute()
                startListening()
            }
            return !hasVolume || volumeListenerBlock != nil
        }
    }

    // MARK: - Volume Control (Task 10.2)

    /// Set volume on the proxy device via CoreAudio API.
    /// UI → Driver → Shared Memory → Host (zero file I/O).
    func setVolume(_ value: Float) {
        let targetDevice: AudioObjectID
        if proxyDeviceID != kAudioObjectUnknown {
            targetDevice = proxyDeviceID
        } else if physicalDeviceID != kAudioObjectUnknown {
            targetDevice = physicalDeviceID
        } else {
            return
        }

        let clamped = max(0.0, min(1.0, value))
        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
        var succeeded = false

        for element in elements {
            var volume = clamped
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )

            let status = AudioObjectSetPropertyData(
                targetDevice, &address, 0, nil,
                UInt32(MemoryLayout<Float>.size), &volume
            )

            if status == noErr {
                succeeded = true
                if element != kAudioObjectPropertyElementMain {
                    logger.info("setVolume succeeded on per-channel element \(element) for device \(targetDevice)")
                }
                // For per-channel elements, continue to set all channels
                if element == kAudioObjectPropertyElementMain { break }
            }
        }

        if succeeded {
            DispatchQueue.main.async { [weak self] in
                self?.currentVolume = clamped
            }
        } else {
            logger.error("setVolume failed on all elements for device \(targetDevice)")
            // Diagnostic: check settable status for each element
            for element in elements {
                var diagAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: element
                )
                var isSettable: DarwinBoolean = false
                let settableStatus = AudioObjectIsPropertySettable(targetDevice, &diagAddress, &isSettable)
                logger.error("  Diagnostic: device=\(targetDevice) element=\(element) settable=\(isSettable.boolValue) settableQueryStatus=\(formatOSStatus(settableStatus))")
            }
        }
    }

    /// Toggle mute on the target device (proxy or physical).
    func setMute(_ muted: Bool) {
        let targetDevice: AudioObjectID
        if proxyDeviceID != kAudioObjectUnknown {
            targetDevice = proxyDeviceID
        } else if physicalDeviceID != kAudioObjectUnknown {
            targetDevice = physicalDeviceID
        } else {
            return
        }

        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]
        var succeeded = false

        for element in elements {
            var value: UInt32 = muted ? 1 : 0
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )

            let status = AudioObjectSetPropertyData(
                targetDevice, &address, 0, nil,
                UInt32(MemoryLayout<UInt32>.size), &value
            )

            if status == noErr {
                succeeded = true
                if element != kAudioObjectPropertyElementMain {
                    logger.info("setMute succeeded on per-channel element \(element) for device \(targetDevice)")
                }
                if element == kAudioObjectPropertyElementMain { break }
            }
        }

        if succeeded {
            DispatchQueue.main.async { [weak self] in
                self?.isMuted = muted
            }
        } else {
            logger.error("setMute failed on all elements for device \(targetDevice)")
        }
    }

    // MARK: - Volume Listening (Task 10.3)

    /// Register AudioObjectPropertyListenerBlock for volume and mute changes
    /// on the proxy device. Keyboard volume key changes update the slider within 100ms.
    private func startListening() {
        let targetDevice: AudioObjectID
        if proxyDeviceID != kAudioObjectUnknown {
            targetDevice = proxyDeviceID
        } else if physicalDeviceID != kAudioObjectUnknown {
            targetDevice = physicalDeviceID
        } else {
            return
        }

        listenedDeviceID = targetDevice

        // Volume listener
        let volBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.readCurrentVolume()
        }
        volumeListenerBlock = volBlock

        let volumeStatus = AudioObjectAddPropertyListenerBlock(
            targetDevice, &volumeAddress, DispatchQueue.main, volBlock
        )
        if volumeStatus != noErr {
            logger.error("Failed to add volume listener: \(formatOSStatus(volumeStatus))")
            volumeListenerBlock = nil
        }

        // Mute listener
        let mtBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.readCurrentMute()
        }
        muteListenerBlock = mtBlock

        let muteStatus = AudioObjectAddPropertyListenerBlock(
            targetDevice, &muteAddress, DispatchQueue.main, mtBlock
        )
        if muteStatus != noErr {
            logger.error("Failed to add mute listener: \(formatOSStatus(muteStatus))")
            muteListenerBlock = nil
        }
    }

    private func stopListening() {
        guard listenedDeviceID != kAudioObjectUnknown else { return }
        if let block = volumeListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                listenedDeviceID, &volumeAddress, DispatchQueue.main, block
            )
            if status != noErr {
                logger.warning("Failed to remove volume listener: \(formatOSStatus(status))")
            }
            volumeListenerBlock = nil
        }
        if let block = muteListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                listenedDeviceID, &muteAddress, DispatchQueue.main, block
            )
            if status != noErr {
                logger.warning("Failed to remove mute listener: \(formatOSStatus(status))")
            }
            muteListenerBlock = nil
        }
        listenedDeviceID = kAudioObjectUnknown
    }

    // MARK: - Hardware Device List Listener (P0 fix: hot-plug + startup race)

    /// Listen for system-wide device list changes (HDMI plug/unplug, Host creating proxy).
    /// Solves both the startup race condition and hot-plug detection.
    private func startHardwareListener() {
        let hwBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshDeviceList()
            self.findAndBindProxyDevice()
        }
        hardwareListenerBlock = hwBlock

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &hardwareDevicesAddress,
            DispatchQueue.main,
            hwBlock
        )
        if status != noErr {
            logger.error("Failed to add hardware devices listener: \(formatOSStatus(status))")
            hardwareListenerBlock = nil
        }

        // 监听默认输出设备变化（用户在系统偏好设置切换设备）
        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.findAndBindProxyDevice()
        }
        defaultOutputListenerBlock = defaultBlock

        let defaultStatus = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            defaultBlock
        )
        if defaultStatus != noErr {
            logger.error("Failed to add default output listener: \(formatOSStatus(defaultStatus))")
            defaultOutputListenerBlock = nil
        }
    }

    private func stopHardwareListener() {
        if let block = hardwareListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &hardwareDevicesAddress,
                DispatchQueue.main,
                block
            )
            if status != noErr {
                logger.warning("Failed to remove hardware devices listener: \(formatOSStatus(status))")
            }
            hardwareListenerBlock = nil
        }
        if let block = defaultOutputListenerBlock {
            let status = AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                DispatchQueue.main,
                block
            )
            if status != noErr {
                logger.warning("Failed to remove default output listener: \(formatOSStatus(status))")
            }
            defaultOutputListenerBlock = nil
        }
    }

    /// coreaudiod 重启后旧设备 ID 和属性监听全部失效，系统通过该属性通知客户端重建。
    private func startServiceRestartListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleServiceRestarted()
        }
        serviceRestartListenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &serviceRestartedAddress,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            logger.error("Failed to add service restart listener: \(formatOSStatus(status))")
            serviceRestartListenerBlock = nil
        }
    }

    private func stopServiceRestartListener() {
        guard let block = serviceRestartListenerBlock else { return }
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &serviceRestartedAddress,
            DispatchQueue.main,
            block
        )
        if status != noErr {
            logger.warning("Failed to remove service restart listener: \(formatOSStatus(status))")
        }
        serviceRestartListenerBlock = nil
    }

    private func handleServiceRestarted() {
        logger.warning("CoreAudio service restarted, rebinding devices")
        serviceRecoveryGeneration += 1
        scheduleServiceRecovery(generation: serviceRecoveryGeneration, attempt: 0)
    }

    /// 代理尚未初始化或监听注册失败时按退避重试，直到绑定完整；新的重启通知会让旧重试失效。
    private func scheduleServiceRecovery(generation: Int, attempt: Int) {
        let delay = Self.serviceRecoveryDelays[attempt]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == self.serviceRecoveryGeneration else { return }
            if self.recoverAfterAudioSystemRestart() {
                logger.info("Devices rebound after CoreAudio service restart (attempt \(attempt + 1))")
            } else if attempt + 1 < Self.serviceRecoveryDelays.count {
                self.scheduleServiceRecovery(generation: generation, attempt: attempt + 1)
            } else {
                logger.error("Device rebinding failed after CoreAudio service restart (\(attempt + 1) attempts)")
            }
        }
    }

    /// Full cleanup — call from applicationWillTerminate.
    func cleanup() {
        stopListening()
        stopHardwareListener()
        stopServiceRestartListener()
    }

    /// Recreate CoreAudio listeners after coreaudiod has been restarted.
    /// 返回设备绑定和系统监听是否全部恢复。
    @discardableResult
    func recoverAfterAudioSystemRestart() -> Bool {
        stopListening()
        stopHardwareListener()
        refreshDeviceList()
        let bound = findAndBindProxyDevice()
        startHardwareListener()
        return bound && hardwareListenerBlock != nil && defaultOutputListenerBlock != nil
    }

    /// Read current volume from the target device (proxy or physical).
    private func readCurrentVolume() {
        let targetDevice: AudioObjectID
        if proxyDeviceID != kAudioObjectUnknown {
            targetDevice = proxyDeviceID
        } else if physicalDeviceID != kAudioObjectUnknown {
            targetDevice = physicalDeviceID
        } else {
            return
        }

        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )

            var volume: Float = 0
            var dataSize = UInt32(MemoryLayout<Float>.size)

            let status = AudioObjectGetPropertyData(
                targetDevice, &address, 0, nil, &dataSize, &volume
            )

            if status == noErr {
                DispatchQueue.main.async { [weak self] in
                    self?.currentVolume = volume
                }
                return
            }
        }

        logger.error("readCurrentVolume failed on all elements for device \(targetDevice)")
    }

    /// Read current mute state from the target device (proxy or physical).
    private func readCurrentMute() {
        let targetDevice: AudioObjectID
        if proxyDeviceID != kAudioObjectUnknown {
            targetDevice = proxyDeviceID
        } else if physicalDeviceID != kAudioObjectUnknown {
            targetDevice = physicalDeviceID
        } else {
            return
        }

        let elements: [UInt32] = [kAudioObjectPropertyElementMain, 1, 2]

        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )

            var muted: UInt32 = 0
            var dataSize = UInt32(MemoryLayout<UInt32>.size)

            let status = AudioObjectGetPropertyData(
                targetDevice, &address, 0, nil, &dataSize, &muted
            )

            if status == noErr {
                DispatchQueue.main.async { [weak self] in
                    self?.isMuted = muted != 0
                }
                return
            }
        }

        logger.error("readCurrentMute failed on all elements for device \(targetDevice)")
    }

    // MARK: - Device Switching (Task 10.5)

    /// Switch the system default output device via CoreAudio API.
    /// Prefers the MoniVol proxy device for the target physical device
    /// so audio continues to flow through the DSP pipeline.
    func switchDevice(to device: OutputDevice) {
        // Try to find the corresponding MoniVol proxy device first.
        // Proxy UIDs follow the pattern: "<physicalUID>-monivol"
        let targetDeviceID = findProxyDeviceID(forPhysicalUID: device.uid) ?? device.id

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID = targetDeviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &deviceID
        )

        if status != noErr {
            logger.error("switchDevice failed: \(formatOSStatus(status))")
        } else if targetDeviceID != device.id {
            logger.info("Switched to proxy device (ID: \(targetDeviceID)) for \(device.name)")
        }
        // 主动选择后立即更新绑定，不依赖 Core Audio 重启后可能失效的监听器。
        if status == noErr {
            findAndBindProxyDevice()
        }
    }

    /// Find the MoniVol proxy device ID for a given physical device UID.
    /// Returns nil if no proxy exists (e.g. Host not running).
    private func findProxyDeviceID(forPhysicalUID physicalUID: String) -> AudioDeviceID? {
        let proxyUID = ProxyNaming.proxyUID(for: physicalUID)
        let allIDs = getAllOutputDeviceIDs()
        for id in allIDs {
            if let uid = DeviceQuery.uid(id), uid == proxyUID {
                return id
            }
        }
        return nil
    }

    // MARK: - CoreAudio Helpers

    private func getDefaultOutputDevice() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress, 0, nil, &dataSize, &deviceID
        ) == noErr else { return nil }

        return deviceID
    }

    private func getAllOutputDeviceIDs() -> [AudioDeviceID] {
        // Filter to output devices only
        return DeviceQuery.allDeviceIDs().filter { DeviceQuery.hasOutputStreams($0) }
    }

    // MARK: - Device Bounce (Reconnect Audio)

    /// Request the Host process to bounce the audio device via IPC.
    /// This triggers a Darwin notification that the Host listens for.
    func bounceDevice() {
        // Use _notify_post to send bounce request to Host — Host is the single
        // source of truth for CoreAudio device control.
        _ = _notify_post(MonivolNotifications.bounceRequest)
        logger.info("Sent bounce request to Host")
    }
}
