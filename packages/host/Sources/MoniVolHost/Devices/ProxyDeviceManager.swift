import Foundation
import CoreAudio
import os.log

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
    private let volumeForwardQueue = DispatchQueue(label: "com.monivol.host.proxy-volume-forward")
    private let volumeForwardEpsilon: Float32 = 0.001
    private var lastForwardedProxyVolume: Float32?
    let volumePersistence: VolumePersistence
    private let preferences = UserDefaults(suiteName: "com.monivol.host") ?? .standard
    private(set) var preferredDisplayUID: String?

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
        let proxyUID = physicalUID + "-monivol"

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
            if let uid = getDeviceUID(deviceID), uid == proxyUID {
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
    func bounceDevice() {
        let proxyID = activeProxyDeviceID
        let physicalID = activePhysicalDeviceID
        guard proxyID != 0, physicalID != 0 else {
            logger.info("[Bounce] No active proxy/physical pair — skipping")
            return
        }

        print("[Bounce] Triggering device bounce to recapture audio streams...")
        isAutoSwitching = true
        bounceUntilTime = Date().addingTimeInterval(1.0) // 1s window for async callbacks

        // Step 1: Switch both default + system output to physical device
        setDefaultAndSystemDevice(physicalID)

        // Step 2: Wait for apps to notice the change
        Thread.sleep(forTimeInterval: 0.2)

        // Step 3: Switch both back to proxy
        setDefaultAndSystemDevice(proxyID)

        lastSwitchTime = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + switchCooldown) { [weak self] in
            self?.isAutoSwitching = false
        }
        print("[Bounce] Device bounce complete")
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

        guard let uid = getDeviceUID(currentDeviceID),
              let name = getDeviceName(currentDeviceID) else {
            logger.error("Could not get device info")
            return
        }

        print("[AutoSelect] Current default device: \(name) (\(uid))")

        if uid.hasSuffix("-monivol") {
            // If we're already on a proxy, make sure we map it to the physical device.
            let physicalUID = String(uid.dropLast("-monivol".count))
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
              let uid = getDeviceUID(currentDeviceID) else {
            return nil
        }

        if uid.hasSuffix("-monivol") {
            let physicalUID = String(uid.dropLast("-monivol".count))
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
        if proxyUID.hasSuffix("-monivol"),
           let physicalDevice = registry.find(uid: String(proxyUID.dropLast("-monivol".count))) {
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
              let name = getDeviceName(currentDeviceID),
              name.contains("MoniVol") else {
            return false
        }

        guard let proxyUID = getDeviceUID(currentDeviceID),
              let physicalUID = proxyUID.components(separatedBy: "-monivol").first,
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

    private func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
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

    private func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
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

    private func stopVolumeForwarding() {
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

        let proxyDeviceID = activeProxyDeviceID
        let physicalDeviceID = activePhysicalDeviceID
        guard proxyDeviceID != 0, physicalDeviceID != 0 else { return }

        volumeForwardQueue.async { [weak self] in
            self?.forwardProxyMuteToPhysical(proxyDeviceID: proxyDeviceID, physicalDeviceID: physicalDeviceID)
        }
    }

    private func forwardProxyMuteToPhysical(proxyDeviceID: AudioDeviceID, physicalDeviceID: AudioDeviceID) {
        guard let muted = getDeviceMute(proxyDeviceID) else { return }
        _ = setDeviceMute(physicalDeviceID, muted: muted)

        // Persist mute state for the physical device
        if let physicalUID = activeProxyUID {
            let volume = getDeviceVolume(proxyDeviceID) ?? VolumePersistence.defaultVolume
            volumePersistence.save(uid: physicalUID, volume: volume, muted: muted)
        }
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
    func reregisterVolumeForwarding(attempt: Int = 1) {
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
                    self?.reregisterVolumeForwarding(attempt: attempt + 1)
                }
            } else {
                logger.error("Listener registration failed after \(MoniVolConfig.wakeRetryMaxAttempts) attempts")
            }
            return
        }

        enqueueProxyVolumeForward(force: true)

        let proxyID = activeProxyDeviceID
        let physicalID = activePhysicalDeviceID
        volumeForwardQueue.async { [weak self] in
            self?.forwardProxyMuteToPhysical(proxyDeviceID: proxyID, physicalDeviceID: physicalID)
        }

        if attempt > 1 {
            logger.info("Volume and mute listeners re-registered after wake (attempt \(attempt))")
        } else {
            logger.info("Volume and mute listeners re-registered after wake")
        }
    }

    private func enqueueProxyVolumeForward(force: Bool = false) {
        let proxyDeviceID = activeProxyDeviceID
        let physicalDeviceID = activePhysicalDeviceID
        guard proxyDeviceID != 0, physicalDeviceID != 0 else {
            return
        }

        volumeForwardQueue.async { [weak self] in
            self?.forwardProxyVolumeToPhysical(
                proxyDeviceID: proxyDeviceID,
                physicalDeviceID: physicalDeviceID,
                force: force
            )
        }
    }

    private func forwardProxyVolumeToPhysical(
        proxyDeviceID: AudioDeviceID,
        physicalDeviceID: AudioDeviceID,
        force: Bool = false
    ) {
        guard let proxyVolume = getDeviceVolume(proxyDeviceID) else {
            return
        }

        if !force, let lastForwardedProxyVolume, abs(proxyVolume - lastForwardedProxyVolume) < volumeForwardEpsilon {
            return
        }

        lastForwardedProxyVolume = proxyVolume
        _ = setDeviceVolume(physicalDeviceID, volume: proxyVolume)

        // Persist volume state for the physical device
        if let physicalUID = activeProxyUID {
            let muted = getDeviceMute(proxyDeviceID) ?? false
            volumePersistence.save(uid: physicalUID, volume: proxyVolume, muted: muted)
        }
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
    manager.handleProxyVolumeChanged(from: objectID)
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
    manager.handleProxyMuteChanged(from: objectID)
    return noErr
}
