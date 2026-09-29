import Foundation
import CoreAudio
import os.log
import MoniVolCore

private let logger = Logger(subsystem: "com.monivol.host", category: "DeviceMonitor")

class DeviceMonitor {
    private let registry: DeviceRegistry
    private let proxyManager: ProxyDeviceManager
    private let memoryManager: SharedMemoryManager
    private let discovery: DeviceDiscovery
    private let audioEngine: AudioEngine
    private var lastHandledDeviceID: AudioDeviceID = 0
    private var lastHandledTime: Date = .distantPast
    private let callbackDebounce: TimeInterval = 0.3
    private var listenersRegistered = false
    private var devicesListenerRegistered = false
    private var defaultOutputListenerRegistered = false
    private var pendingProxyUIDs: Set<String> = []

    init(
        registry: DeviceRegistry,
        proxyManager: ProxyDeviceManager,
        memoryManager: SharedMemoryManager,
        discovery: DeviceDiscovery,
        audioEngine: AudioEngine
    ) {
        self.registry = registry
        self.proxyManager = proxyManager
        self.memoryManager = memoryManager
        self.discovery = discovery
        self.audioEngine = audioEngine
    }

    func registerListeners() {
        guard !listenersRegistered else { return }

        // SAFETY: self 是 main.swift 中的全局 let 变量，生命周期与进程一致。
        // passUnretained 安全，因为 self 不会在回调存活期间被释放。
        // 如果未来改为非全局实例，必须改用 passRetained + 配对 release。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devicesStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            deviceListChangedCallbackC,
            selfPtr
        )
        devicesListenerRegistered = (devicesStatus == noErr)
        if devicesStatus != noErr {
            logger.error("Failed to register devices listener (OSStatus: \(devicesStatus))")
        }

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let outputStatus = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            defaultOutputChangedCallbackC,
            selfPtr
        )
        defaultOutputListenerRegistered = (outputStatus == noErr)
        if outputStatus != noErr {
            logger.error("Failed to register default output listener (OSStatus: \(outputStatus))")
        }

        listenersRegistered = devicesListenerRegistered && defaultOutputListenerRegistered
    }

    private func removeListeners() {
        guard devicesListenerRegistered || defaultOutputListenerRegistered else { return }
        listenersRegistered = false

        // SAFETY: self 是 main.swift 中的全局 let 变量，生命周期与进程一致。
        // passUnretained 安全，因为 self 不会在回调存活期间被释放。
        // 如果未来改为非全局实例，必须改用 passRetained + 配对 release。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if devicesListenerRegistered {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                deviceListChangedCallbackC,
                selfPtr
            )
            devicesListenerRegistered = false
        }

        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if defaultOutputListenerRegistered {
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultOutputAddress,
                defaultOutputChangedCallbackC,
                selfPtr
            )
            defaultOutputListenerRegistered = false
        }
    }

    func stopListening() {
        removeListeners()
    }

    func reregisterListeners() {
        removeListeners()
        registerListeners()
        logger.info("Listeners re-registered after wake")
    }

    func resetDebounce() {
        lastHandledDeviceID = 0
        lastHandledTime = .distantPast
    }

    fileprivate func handleDeviceListChanged() {
        let oldDevices = registry.devices
        let physicalOutputs = discovery.enumeratePhysicalDevices()
        let newDevices = physicalOutputs.filter { $0.needsDisplayProxy }

        let addedDevices = newDevices.filter { new in
            !oldDevices.contains { $0.uid == new.uid }
        }
        let removedDevices = oldDevices.filter { old in
            !newDevices.contains { $0.uid == old.uid }
        }

        // 1. Create shared memory for new devices
        for device in addedDevices {
            print("Device added: \(device.name) (\(discovery.transportTypeName(device.transportType)))")
            _ = memoryManager.createMemory(for: device.uid)
        }

        for device in removedDevices {
            print("Device removed: \(device.name) (\(discovery.transportTypeName(device.transportType)))")
        }

        if removedDevices.contains(where: { $0.uid == proxyManager.preferredDisplayUID }) {
            // Keep the preferred display UID for the next connection.
            proxyManager.clearActiveProxy()
            audioEngine.stop()
            if let builtIn = physicalOutputs.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn }) {
                _ = proxyManager.setDefaultOutputDevice(builtIn.id)
            }
        }

        // 2. 代理设备列表变化不应重复触发驱动同步。
        let devicesChanged = oldDevices.count != newDevices.count ||
            !oldDevices.allSatisfy { old in
                guard let new = newDevices.first(where: { $0.uid == old.uid }) else { return false }
                return old.id == new.id && old.uid == new.uid && old.name == new.name &&
                    old.transportType == new.transportType && old.isFixedVolume == new.isFixedVolume &&
                    old.validationPassed == new.validationPassed
            }
        if devicesChanged {
            registry.update(newDevices)
        }

        // 3. Delay shared memory removal for removed devices
        if !removedDevices.isEmpty {
            let removedUIDs = removedDevices.map { $0.uid }
            DispatchQueue.main.asyncAfter(deadline: .now() + MoniVolConfig.cleanupWaitTimeout) {
                [weak self] in
                guard let self else { return }
                for uid in removedUIDs {
                    if self.registry.find(uid: uid) == nil {
                        self.memoryManager.removeMemory(for: uid)
                    }
                }
            }
        }

        // 4. Wait for proxy devices and auto-switch for new devices
        if !addedDevices.isEmpty {
            waitForProxyAndSwitch(addedDevices: addedDevices)
        }
        // NOTE: reloadDriver() removed — Darwin notifications replace manual reload
    }

    fileprivate func handleDefaultOutputChanged() {
        // Skip during device bounce to prevent audio engine thrashing
        guard !proxyManager.isDeviceBouncing else { return }

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else {
            return
        }

        // Debounce: skip if same device within cooldown period
        let now = Date()
        if deviceID == lastHandledDeviceID && now.timeIntervalSince(lastHandledTime) < callbackDebounce {
            return
        }
        lastHandledDeviceID = deviceID
        lastHandledTime = now

        guard let name = DeviceQuery.name(deviceID),
              let uid = DeviceQuery.uid(deviceID) else {
            return
        }

        print("Default output changed: \(name)")

        if ProxyNaming.isProxyUID(uid) {
            proxyManager.handleProxySelection(uid, deviceID: deviceID)

            let targetID = proxyManager.activePhysicalDeviceID
            if targetID != 0 {
                do {
                    try audioEngine.switchDevice(targetID)
                } catch {
                    logger.error("Failed to switch audio engine device: \(error.localizedDescription)")
                }
            } else {
                logger.warning("No active physical device mapped for proxy \(uid)")
            }
        } else {
            if registry.find(uid: uid) != nil {
                proxyManager.handlePhysicalSelection(uid)
                if proxyManager.activeProxyDeviceID == 0,
                   let display = registry.find(uid: uid) {
                    audioEngine.stop()
                    waitForProxyAndSwitch(addedDevices: [display])
                }
            } else {
                // A native selection while the display is connected is intentional.
                // During unplug, retain the UID so reconnect can restore it.
                if let preferred = proxyManager.preferredDisplayUID,
                   discovery.enumeratePhysicalDevices().contains(where: { $0.uid == preferred && $0.needsDisplayProxy }) {
                    proxyManager.forgetDisplay()
                }
                proxyManager.clearActiveProxy()
                audioEngine.stop()
            }
        }
    }

    private func waitForProxyAndSwitch(addedDevices: [PhysicalDevice]) {
        for device in addedDevices where device.uid == proxyManager.preferredDisplayUID {
            guard pendingProxyUIDs.insert(device.uid).inserted else { continue }
            waitForProxyAndSwitch(device, deadline: Date().addingTimeInterval(MoniVolConfig.deviceWaitTimeout))
        }
    }

    private func waitForProxyAndSwitch(_ device: PhysicalDevice, deadline: Date) {
        guard registry.find(uid: device.uid) != nil,
              proxyManager.preferredDisplayUID == device.uid else {
            pendingProxyUIDs.remove(device.uid)
            return
        }

        if proxyManager.findProxyDevice(forPhysicalUID: device.uid) != nil {
            proxyManager.handlePhysicalSelection(device.uid)
            if proxyManager.activeProxyUID == device.uid,
               proxyManager.activeProxyDeviceID != 0 {
                pendingProxyUIDs.remove(device.uid)
                return
            }
        }
        guard Date() < deadline else {
            pendingProxyUIDs.remove(device.uid)
            logger.warning("Proxy device not found for \(device.name) after \(MoniVolConfig.deviceWaitTimeout)s timeout")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForProxyAndSwitch(device, deadline: deadline)
        }
    }
}

// File-level C callbacks — stable function pointers required for AudioObjectRemovePropertyListener.
// AudioObjectPropertyListenerProc requires non-optional UnsafePointer<AudioObjectPropertyAddress>.
private func deviceListChangedCallbackC(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async { monitor.handleDeviceListChanged() }
    return noErr
}

private func defaultOutputChangedCallbackC(
    _ objectID: AudioObjectID,
    _ numAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async { monitor.handleDefaultOutputChanged() }
    return noErr
}
