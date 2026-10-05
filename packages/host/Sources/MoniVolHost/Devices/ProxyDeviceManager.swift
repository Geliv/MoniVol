import Foundation
import CoreAudio
import os.log
import MoniVolCore

private let logger = Logger(subsystem: "com.monivol.host", category: "ProxyDeviceManager")

class ProxyDeviceManager {
    private let registry: DeviceRegistry
    private var isAutoSwitching = false
    /// Timestamp until which DeviceMonitor should ignore default-output changes (bounce window).
    private var bounceUntilTime: Date = .distantPast
    /// Whether a device bounce is in progress (checked by DeviceMonitor).
    var isDeviceBouncing: Bool { Date() < bounceUntilTime }
    private var lastSwitchTime: Date = .distantPast
    private let switchCooldown: TimeInterval = 0.5
    private var monitoredProxyDeviceID: AudioDeviceID?
    private var monitoredVolumeElements: [UInt32] = []
    private var monitoredMuteRegistered = false
    /// 每次发起或取消音量监听重注册都会递增，旧的重试任务据此失效。
    private var volumeForwardingRetryGeneration = 0
    private let volumeForwardQueue = DispatchQueue(label: "com.monivol.host.proxy-volume-forward")
    private let volumeForwardEpsilon: Float32 = 0.001
    private var lastForwardedProxyVolume: Float32?
    let volumePersistence: VolumePersistence
    private let preferences = UserDefaults(suiteName: "com.monivol.host") ?? .standard
    private(set) var preferredDisplayUID: String?
    var onActiveProxyChanged: ((String?) -> Void)?
    /// bounce 窗口结束后在主线程调用，用于按实际默认输出重新同步路由和音频引擎。
    var onBounceFinished: (() -> Void)?
    private let bounceWindow: TimeInterval = 1.0

    func rememberDisplay(_ uid: String) {
        preferredDisplayUID = uid
        preferences.set(uid, forKey: "preferredDisplayUID")
    }

    func forgetDisplay() {
        preferredDisplayUID = nil
        preferences.removeObject(forKey: "preferredDisplayUID")
    }

    var activeProxyUID: String? {
        didSet {
            registry.activeDeviceUID = activeProxyUID
            registry.writeDeviceStateFile()
            onActiveProxyChanged?(activeProxyUID)
        }
    }
    var activePhysicalDeviceID: AudioDeviceID = 0
    var activeProxyDeviceID: AudioDeviceID = 0

    init(registry: DeviceRegistry, volumePersistence: VolumePersistence = VolumePersistence()) {
        self.registry = registry
        self.volumePersistence = volumePersistence
        let savedUID = preferences.string(forKey: "preferredDisplayUID")
            ?? UserDefaults(suiteName: "com.soundbridge.host")?.string(forKey: "preferredDisplayUID")
        self.preferredDisplayUID = savedUID
        if preferences.string(forKey: "preferredDisplayUID") == nil, let savedUID {
            preferences.set(savedUID, forKey: "preferredDisplayUID")
        }
    }

    deinit {
        stopVolumeForwarding()
    }

    func clearActiveProxy() {
        stopVolumeForwarding()
        activeProxyUID = nil
        activePhysicalDeviceID = 0
        activeProxyDeviceID = 0
        isAutoSwitching = false
    }

    func findProxyDevice(forPhysicalUID physicalUID: String) -> AudioDeviceID? {
        let proxyUID = ProxyNaming.proxyUID(for: physicalUID)

        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        for deviceID in deviceIDs {
            if let uid = DeviceQuery.uid(deviceID), uid == proxyUID {
                return deviceID
            }
        }

        return nil
    }

    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var newDeviceID = deviceID
        let result = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &newDeviceID
        )

        // Also set system output device (system sounds / alerts)
        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var systemDeviceID = deviceID
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &systemAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &systemDeviceID
        )

        return result == noErr
    }

    /// Bounce the default device: proxy → physical → proxy.
    /// Forces apps that cache the device ID to re-bind to the new default.
    /// Must be called on the main queue; routing state is main-thread only.
    func bounceDevice() {
        guard !isDeviceBouncing else {
            logger.info("[Bounce] Already in progress — skipping")
            return
        }
        guard let physicalUID = activeProxyUID,
              activeProxyDeviceID != 0, activePhysicalDeviceID != 0 else {
            logger.info("[Bounce] No active proxy/physical pair — syncing with current output")
            onBounceFinished?()
            return
        }
        let physicalID = activePhysicalDeviceID

        print("[Bounce] Triggering device bounce to recapture audio streams...")
        // DeviceMonitor ignores default-output changes inside this window.
        bounceUntilTime = Date().addingTimeInterval(bounceWindow)

        // Step 1: Switch both default + system output to physical device
        setDefaultAndSystemDevice(physicalID)

        // Step 2: Give apps time to notice, then switch back to the proxy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            // 返回代理前确认显示器仍连接，且用户没有在等待期间选择其他输出。
            if self.activeProxyUID == physicalUID,
               self.registry.find(uid: physicalUID) != nil,
               self.getCurrentDefaultDevice() == physicalID,
               let proxyID = self.findProxyDevice(forPhysicalUID: physicalUID) {
                self.setDefaultAndSystemDevice(proxyID)
                print("[Bounce] Device bounce complete")
            } else {
                logger.info("[Bounce] Output changed during bounce — not returning to proxy")
            }
        }

        // Step 3: After the window, resync routing and the engine with the actual default output
        DispatchQueue.main.asyncAfter(deadline: .now() + bounceWindow) { [weak self] in
            guard let self else { return }
            self.bounceUntilTime = .distantPast
            self.onBounceFinished?()
        }
    }

    /// Set both default output and system output device in one call.
    private func setDefaultAndSystemDevice(_ deviceID: AudioDeviceID) {
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id1 = deviceID
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id1
        )

        var systemAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id2 = deviceID
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &systemAddress, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id2
        )
    }

    func autoSelectProxy(fallbackDeviceID: AudioDeviceID? = nil) {
        guard let currentDeviceID = getCurrentDefaultDevice() else {
            logger.error("Could not get current default device")
            return
        }

        guard let uid = DeviceQuery.uid(currentDeviceID),
              let name = DeviceQuery.name(currentDeviceID) else {
            logger.error("Could not get device info")
            return
        }

        print("[AutoSelect] Current default device: \(name) (\(uid))")

        if ProxyNaming.isProxyUID(uid) {
            // If we're already on a proxy, make sure we map it to the physical device.
            let physicalUID = ProxyNaming.physicalUID(from: uid) ?? uid
            if let physicalDevice = registry.find(uid: physicalUID) {
                rememberDisplay(physicalUID)
                activeProxyUID = physicalUID
                activePhysicalDeviceID = physicalDevice.id
                activeProxyDeviceID = currentDeviceID
                startVolumeForwarding(proxyDeviceID: currentDeviceID)
                enqueueProxyVolumeForward(force: true)
                restoreVolumeState(proxyDeviceID: currentDeviceID, physicalUID: physicalUID)
                print("[AutoSelect] Already on proxy device - mapped to \(physicalDevice.name)")
            } else {
                print("[AutoSelect] Already on proxy device - but no physical mapping found")
                clearActiveProxy()
                if let fallbackDeviceID {
                    _ = setDefaultOutputDevice(fallbackDeviceID)
                }
            }
            return
        }

        let selectedUID = registry.find(uid: uid) != nil ? uid : preferredDisplayUID
        guard let selectedUID, let selectedDevice = registry.find(uid: selectedUID) else {
            print("[AutoSelect] No selected display needs a proxy")
            return
        }

        guard let proxyID = findProxyDevice(forPhysicalUID: selectedUID) else {
            logger.warning("Could not find proxy for device: \(name)")
            return
        }

        // Capture physical volume and sync to proxy BEFORE switching
        let originalVolume = uid == selectedUID ? getDeviceVolume(currentDeviceID) : nil
        if let volume = originalVolume {
            print("[AutoSelect] Physical device volume: \(String(format: "%.0f%%", volume * 100))")
            if setDeviceVolume(proxyID, volume: volume) {
                logger.info("Set proxy volume to \(String(format: "%.0f%%", volume * 100))")
            }
        }

        print("[AutoSelect] Switching to proxy device...")
        isAutoSwitching = true
        lastSwitchTime = Date()
        if setDefaultOutputDevice(proxyID) {
            logger.info("Successfully switched to proxy")
            rememberDisplay(selectedUID)
            activeProxyUID = selectedUID
            activePhysicalDeviceID = selectedDevice.id
            activeProxyDeviceID = proxyID
            startVolumeForwarding(proxyDeviceID: proxyID)
            enqueueProxyVolumeForward(force: true)
            restoreVolumeState(proxyDeviceID: proxyID, physicalUID: selectedUID)
        } else {
            logger.error("Failed to set proxy as default")
            isAutoSwitching = false
        }
    }

    /// Resolve the current output device to a physical device, if possible.
    /// If current output is a proxy, this also updates activeProxy* state.
    func resolveCurrentOutputDevice(in devices: [PhysicalDevice]) -> PhysicalDevice? {
        guard let currentDeviceID = getCurrentDefaultDevice(),
              let uid = DeviceQuery.uid(currentDeviceID) else {
            return nil
        }

        if ProxyNaming.isProxyUID(uid) {
            let physicalUID = ProxyNaming.physicalUID(from: uid) ?? uid
            if let physicalDevice = devices.first(where: { $0.uid == physicalUID }) {
                activeProxyUID = physicalUID
                activePhysicalDeviceID = physicalDevice.id
                activeProxyDeviceID = currentDeviceID
                return physicalDevice
            }
            return nil
        }

        return devices.first(where: { $0.uid == uid })
    }

    func handleProxySelection(_ proxyUID: String, deviceID: AudioDeviceID) {
        if let physicalUID = ProxyNaming.physicalUID(from: proxyUID),
           let physicalDevice = registry.find(uid: physicalUID) {
            let physicalUID = physicalDevice.uid
            rememberDisplay(physicalUID)
            print("Routing to: \(physicalDevice.name)")

            activeProxyUID = physicalUID
            activePhysicalDeviceID = physicalDevice.id
            activeProxyDeviceID = deviceID
            startVolumeForwarding(proxyDeviceID: deviceID)
            enqueueProxyVolumeForward(force: true)
            restoreVolumeState(proxyDeviceID: deviceID, physicalUID: physicalUID)
        } else {
            // The selected proxy has no physical mapping (stale/unplugged). Tear down forwarding state.
            clearActiveProxy()
        }

        // Delay resetting the flag to prevent race conditions with rapid callbacks
        DispatchQueue.main.asyncAfter(deadline: .now() + switchCooldown) { [weak self] in
            self?.isAutoSwitching = false
        }
    }

    func handlePhysicalSelection(_ physicalUID: String) {
        let now = Date()
        guard let physicalDevice = registry.find(uid: physicalUID) else {
            clearActiveProxy()
            return
        }

        rememberDisplay(physicalUID)

        if let proxyID = findProxyDevice(forPhysicalUID: physicalUID) {
            // Sync volume before switching
            if let volume = getDeviceVolume(physicalDevice.id) {
                _ = setDeviceVolume(proxyID, volume: volume)
            }

            print("Auto-switching to MoniVol proxy")
            isAutoSwitching = true
            lastSwitchTime = now
            if setDefaultOutputDevice(proxyID) {
                activeProxyUID = physicalUID
                activeProxyDeviceID = proxyID
                activePhysicalDeviceID = physicalDevice.id
                startVolumeForwarding(proxyDeviceID: proxyID)
                enqueueProxyVolumeForward(force: true)
                restoreVolumeState(proxyDeviceID: proxyID, physicalUID: physicalUID)
            } else {
                logger.error("Failed to switch system default output to proxy device")
                isAutoSwitching = false
                stopVolumeForwarding()
            }
        } else {
            clearActiveProxy()
            logger.warning("No proxy found for this device")
        }
        // Note: isAutoSwitching is reset in handleProxySelection after delay
    }

    func restorePhysicalDevice() -> Bool {
        stopVolumeForwarding()

        guard let currentDeviceID = getCurrentDefaultDevice(),
              let name = DeviceQuery.name(currentDeviceID),
              name.contains(ProxyNaming.nameMarker) else {
            return false
        }

        guard let proxyUID = DeviceQuery.uid(currentDeviceID),
              let physicalUID = ProxyNaming.physicalUID(from: proxyUID),
              let physicalDevice = registry.find(uid: physicalUID) else {
            return false
        }

        // Restore both default and system output to physical device
        setDefaultAndSystemDevice(physicalDevice.id)

        logger.info("Restored to \(physicalDevice.name)")
        Thread.sleep(forTimeInterval: MoniVolConfig.physicalDeviceSwitchDelay)
        return true
    }

    private func getCurrentDefaultDevice() -> AudioDeviceID? {
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
            return nil
        }

        return deviceID
    }

    private func getDeviceVolume(_ deviceID: AudioDeviceID) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Try getting master volume
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var dataSize = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &volume
            )
            if status == noErr {
                return volume
            }
        }

        // Try getting channel 1 volume (left channel)
        address.mElement = 1
        if AudioObjectHasProperty(deviceID, &address) {
            var volume: Float32 = 0
            var dataSize = UInt32(MemoryLayout<Float32>.size)
            let status = AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                &volume
            )
            if status == noErr {
                return volume
            }
        }

        return nil
    }

    private func setDeviceVolume(_ deviceID: AudioDeviceID, volume: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // Try setting master volume
        if AudioObjectHasProperty(deviceID, &address) {
            var vol = volume
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float32>.size),
                &vol
            )
            if status == noErr {
                return true
            }
        }

        // Try setting per-channel volume (channel 1 and 2) if master failed
        var channelSet = false
        for channel: UInt32 in 1...2 {
            address.mElement = channel
            if AudioObjectHasProperty(deviceID, &address) {
                var vol = volume
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float32>.size),
                    &vol
                )
                if status == noErr {
                    channelSet = true
                }
            }
        }

        return channelSet
    }

    private func startVolumeForwarding(proxyDeviceID: AudioDeviceID) {
        if monitoredProxyDeviceID == proxyDeviceID {
            return
        }

        stopVolumeForwarding()
        monitoredProxyDeviceID = proxyDeviceID
        monitoredVolumeElements.removeAll(keepingCapacity: true)
        volumeForwardQueue.async { [weak self] in
            self?.lastForwardedProxyVolume = nil
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        // SAFETY: self 是 main.swift 中的全局 let 变量，生命周期与进程一致。
        // passUnretained 安全，因为 self 不会在回调存活期间被释放。
        // 如果未来改为非全局实例，必须改用 passRetained + 配对 release。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Prefer a single master listener to avoid duplicate callback bursts.
        if AudioObjectHasProperty(proxyDeviceID, &address) {
            let status = AudioObjectAddPropertyListener(proxyDeviceID, &address, proxyVolumeChangedCallback, selfPtr)
            if status == noErr {
                monitoredVolumeElements.append(kAudioObjectPropertyElementMain)
            } else {
                logger.error("Failed to add master listener (OSStatus: \(status))")
            }
        }

        // Fallback to channel listeners only when master is unavailable.
        if monitoredVolumeElements.isEmpty {
            for channel: UInt32 in 1...2 {
                address.mElement = channel
                guard AudioObjectHasProperty(proxyDeviceID, &address) else { continue }
                let status = AudioObjectAddPropertyListener(proxyDeviceID, &address, proxyVolumeChangedCallback, selfPtr)
                if status == noErr {
                    monitoredVolumeElements.append(channel)
                } else {
                    logger.error("Failed to add listener for channel \(channel) (OSStatus: \(status))")
                }
            }
        }

        if monitoredVolumeElements.isEmpty {
            monitoredProxyDeviceID = nil
            logger.warning("No volume listener registered for proxy device \(proxyDeviceID)")
            return
        }

        // Register mute listener (mute key, distinct from volume scalar)
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(proxyDeviceID, &muteAddress) {
            let status = AudioObjectAddPropertyListener(proxyDeviceID, &muteAddress, proxyMuteChangedCallback, selfPtr)
            if status == noErr {
                monitoredMuteRegistered = true
            } else {
                logger.error("Failed to add mute listener (OSStatus: \(status))")
            }
        }
    }

    /// 当前代理的音量监听是否已成功注册。
    var isVolumeForwardingActive: Bool {
        activeProxyDeviceID != 0 && monitoredProxyDeviceID == activeProxyDeviceID
            && !monitoredVolumeElements.isEmpty
    }

    func stopVolumeForwarding() {
        guard let proxyDeviceID = monitoredProxyDeviceID else { return }
        defer {
            monitoredProxyDeviceID = nil
            monitoredVolumeElements.removeAll(keepingCapacity: false)
            monitoredMuteRegistered = false
            volumeForwardQueue.async { [weak self] in
                self?.lastForwardedProxyVolume = nil
            }
        }

        // SAFETY: self 是 main.swift 中的全局 let 变量，生命周期与进程一致。
        // passUnretained 安全，因为 self 不会在回调存活期间被释放。
        // 如果未来改为非全局实例，必须改用 passRetained + 配对 release。
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        for element in monitoredVolumeElements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: element
            )
            let status = AudioObjectRemovePropertyListener(proxyDeviceID, &address, proxyVolumeChangedCallback, selfPtr)
            if status != noErr {
                logger.error("Failed to remove listener for element \(element) (OSStatus: \(status))")
            }
        }

        if monitoredMuteRegistered {
            var muteAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectRemovePropertyListener(proxyDeviceID, &muteAddress, proxyMuteChangedCallback, selfPtr)
            if status != noErr {
                logger.error("Failed to remove mute listener (OSStatus: \(status))")
            }
        }
    }

    fileprivate func handleProxyVolumeChanged(from objectID: AudioObjectID) {
        guard monitoredProxyDeviceID == objectID, activeProxyDeviceID == objectID else {
            return
        }

        enqueueProxyVolumeForward()
    }

    fileprivate func handleProxyMuteChanged(from objectID: AudioObjectID) {
        guard monitoredProxyDeviceID == objectID, activeProxyDeviceID == objectID else {
            return
        }

        enqueueProxyMuteForward()
    }

    private func enqueueProxyMuteForward() {
        guard let route = activeRouteSnapshot() else { return }
        volumeForwardQueue.async { [weak self] in
            self?.forwardProxyMuteToPhysical(route)
        }
    }

    private func forwardProxyMuteToPhysical(_ route: RouteSnapshot) {
        guard let muted = getDeviceMute(route.proxyDeviceID) else { return }
        _ = setDeviceMute(route.physicalDeviceID, muted: muted)

        // Persist mute state for the physical device
        let volume = getDeviceVolume(route.proxyDeviceID) ?? VolumePersistence.defaultVolume
        volumePersistence.save(uid: route.physicalUID, volume: volume, muted: muted)
    }

    private func getDeviceMute(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var muted: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &muted) == noErr else { return nil }
        return muted != 0
    }

    private func setDeviceMute(_ deviceID: AudioDeviceID, muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(
            deviceID, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &value
        ) == noErr
    }

    /// Restore persisted volume and mute state to a proxy device via HAL API.
    /// Called when a device connects or a proxy is selected.
    func restoreVolumeState(proxyDeviceID: AudioDeviceID, physicalUID: String) {
        let state = volumePersistence.load(uid: physicalUID)
        let restored = setDeviceVolume(proxyDeviceID, volume: state.volumeScalar)
        let muteRestored = setDeviceMute(proxyDeviceID, muted: state.isMuted)
        logger.info("Restored volume state for \(physicalUID): volume=\(String(format: "%.0f%%", state.volumeScalar * 100)), muted=\(state.isMuted) (vol:\(restored), mute:\(muteRestored))")
    }

    /// Re-register the proxy volume listener after sleep/wake.
    ///
    /// coreaudiod silently drops all AudioObjectAddPropertyListener registrations
    /// when it restarts (which happens on sleep/wake). Calling startVolumeForwarding
    /// directly would no-op if the proxy device ID is unchanged (the common case),
    /// so we force teardown first to clear monitoredProxyDeviceID and bypass that guard.
    ///
    /// Because coreaudiod may not be ready immediately after wake, this method retries
    /// registration with increasing delays if the initial attempt fails.
    func reregisterVolumeForwarding() {
        volumeForwardingRetryGeneration += 1
        reregisterVolumeForwarding(attempt: 1, generation: volumeForwardingRetryGeneration)
    }

    /// 让尚未执行的音量监听重注册任务失效，例如 coreaudiod 重启后改由服务恢复流程重建时。
    func cancelVolumeForwardingRetries() {
        volumeForwardingRetryGeneration += 1
    }

    private func reregisterVolumeForwarding(attempt: Int, generation: Int) {
        guard generation == volumeForwardingRetryGeneration else { return }

        // stopVolumeForwarding clears monitoredProxyDeviceID, so the same-ID
        // early-return guard in startVolumeForwarding will not block re-registration.
        stopVolumeForwarding()

        guard activeProxyDeviceID != 0 else {
            print("[VolumeForward] No active proxy — skipping re-registration")
            return
        }

        startVolumeForwarding(proxyDeviceID: activeProxyDeviceID)

        if monitoredVolumeElements.isEmpty {
            if attempt < MoniVolConfig.wakeRetryMaxAttempts {
                let delay = MoniVolConfig.wakeRetryDelays[attempt]
                print("[VolumeForward] Listener registration failed (attempt \(attempt)/\(MoniVolConfig.wakeRetryMaxAttempts)) — retrying in \(delay)s")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.reregisterVolumeForwarding(attempt: attempt + 1, generation: generation)
                }
            } else {
                logger.error("Listener registration failed after \(MoniVolConfig.wakeRetryMaxAttempts) attempts")
            }
            return
        }

        enqueueProxyVolumeForward(force: true)
        enqueueProxyMuteForward()

        if attempt > 1 {
            logger.info("Volume and mute listeners re-registered after wake (attempt \(attempt))")
        } else {
            logger.info("Volume and mute listeners re-registered after wake")
        }
    }

    /// Routing identity captured on the main thread for background volume tasks.
    private struct RouteSnapshot {
        let physicalUID: String
        let proxyDeviceID: AudioDeviceID
        let physicalDeviceID: AudioDeviceID
    }

    /// 在主线程取完整快照，后台任务不再读取可能已经变化的路由状态，
    /// 避免切换显示器时把上一台显示器的音量保存到新显示器的 UID 下。
    private func activeRouteSnapshot() -> RouteSnapshot? {
        guard let physicalUID = activeProxyUID,
              activeProxyDeviceID != 0, activePhysicalDeviceID != 0 else {
            return nil
        }
        return RouteSnapshot(
            physicalUID: physicalUID,
            proxyDeviceID: activeProxyDeviceID,
            physicalDeviceID: activePhysicalDeviceID
        )
    }

    private func enqueueProxyVolumeForward(force: Bool = false) {
        guard let route = activeRouteSnapshot() else { return }
        volumeForwardQueue.async { [weak self] in
            self?.forwardProxyVolumeToPhysical(route, force: force)
        }
    }

    private func forwardProxyVolumeToPhysical(_ route: RouteSnapshot, force: Bool) {
        guard let proxyVolume = getDeviceVolume(route.proxyDeviceID) else {
            return
        }

        if !force, let lastForwardedProxyVolume, abs(proxyVolume - lastForwardedProxyVolume) < volumeForwardEpsilon {
            return
        }

        lastForwardedProxyVolume = proxyVolume
        _ = setDeviceVolume(route.physicalDeviceID, volume: proxyVolume)

        // Persist volume state for the physical device
        let muted = getDeviceMute(route.proxyDeviceID) ?? false
        volumePersistence.save(uid: route.physicalUID, volume: proxyVolume, muted: muted)
    }
}

private func proxyVolumeChangedCallback(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let manager = Unmanaged<ProxyDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    // 回调运行在 HAL 通知线程；路由状态只在主线程读写。
    DispatchQueue.main.async { manager.handleProxyVolumeChanged(from: objectID) }
    return noErr
}

private func proxyMuteChangedCallback(
    _ objectID: AudioObjectID,
    _ numberAddresses: UInt32,
    _ addresses: UnsafePointer<AudioObjectPropertyAddress>,
    _ clientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData else { return noErr }
    let manager = Unmanaged<ProxyDeviceManager>.fromOpaque(clientData).takeUnretainedValue()
    DispatchQueue.main.async { manager.handleProxyMuteChanged(from: objectID) }
    return noErr
}
