import Foundation
import CoreAudio
import AudioToolbox
import os.log

private let logger = Logger(subsystem: "com.monivol.host", category: "AudioEngine")

class AudioEngine {
    private static let maximumFramesPerSlice: UInt32 = 4096

    private let renderer: AudioRenderer
    private let registry: DeviceRegistry
    private var outputUnit: AudioUnit?
    private var currentDeviceID: AudioDeviceID?

    init(renderer: AudioRenderer, registry: DeviceRegistry) {
        self.renderer = renderer
        self.registry = registry
    }

    /// Setup with device fallback - tries preferred device first, then validated devices
    func setup(devices: [PhysicalDevice], preferredDeviceID: AudioDeviceID? = nil) throws {
        guard !devices.isEmpty else {
            throw AudioEngineError.noPhysicalDeviceFound
        }

        var lastError: AudioEngineError?

        // Try preferred device FIRST if specified
        if let preferredID = preferredDeviceID,
           let preferredDevice = devices.first(where: { $0.id == preferredID }) {
            let validationStatus = preferredDevice.validationPassed ? "✓" : "⚠"
            print("[AudioEngine] Trying preferred device: \(preferredDevice.name) \(validationStatus)")

            if !preferredDevice.validationPassed {
                logger.warning("\(preferredDevice.validationNote ?? "Device may not work properly")")
            }

            do {
                try setupWithDevice(preferredDevice)
                logger.info("Successfully bound to preferred device: \(preferredDevice.name)")
                return
            } catch let error as AudioEngineError {
                logger.error("Preferred device failed: \(error.description)")
                print("[AudioEngine] Falling back to other devices...")
                lastError = error
                cleanupFailedSetup()
            }
        }

        // Sort remaining devices: validated first, then by original order
        let remainingDevices = devices.filter { $0.id != preferredDeviceID }
        let sortedDevices = remainingDevices.sorted { d1, d2 in
            if d1.validationPassed && !d2.validationPassed { return true }
            if !d1.validationPassed && d2.validationPassed { return false }
            return false // Maintain original order within same validation status
        }

        let validatedCount = sortedDevices.filter { $0.validationPassed }.count
        print("[AudioEngine] Attempting fallback with \(sortedDevices.count) devices (\(validatedCount) validated)")

        for (index, device) in sortedDevices.enumerated() {
            let validationStatus = device.validationPassed ? "✓" : "⚠"
            print("[AudioEngine] [\(index + 1)/\(sortedDevices.count)] Trying: \(device.name) \(validationStatus)")

            if !device.validationPassed {
                logger.warning("\(device.validationNote ?? "Device may not work properly")")
            }

            do {
                try setupWithDevice(device)
                logger.info("Successfully bound to: \(device.name)")
                return
            } catch let error as AudioEngineError {
                logger.error("Failed: \(error.description)")
                lastError = error
                cleanupFailedSetup()
            }
        }

        // All devices failed
        throw lastError ?? AudioEngineError.allDevicesFailed
    }

    /// Legacy setup method - uses registry
    func setup() throws {
        try setup(devices: registry.devices)
    }

    /// Attempt setup with a specific device
    private func setupWithDevice(_ device: PhysicalDevice) throws {
        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw AudioEngineError.componentNotFound
        }

        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw AudioEngineError.instanceCreationFailed(status)
        }

        outputUnit = audioUnit

        try setOutputDevice(device.id)
        try setMaximumFramesPerSlice()
        try setFormat()
        try setRenderCallback()
        try initialize()

        currentDeviceID = device.id

        print("    Using device ID: \(device.id)")
    }

    /// Cleanup after a failed setup attempt
    private func cleanupFailedSetup() {
        guard let unit = outputUnit else { return }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        outputUnit = nil
        currentDeviceID = nil
    }

    func start() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioEngineError.startFailed(status)
        }
    }

    func stop() {
        guard let unit = outputUnit else { return }

        print("[Cleanup] Stopping audio unit...")
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        outputUnit = nil
        currentDeviceID = nil
    }

    func switchDevice(_ deviceID: AudioDeviceID) throws {
        if outputUnit == nil {
            guard let device = registry.devices.first(where: { $0.id == deviceID }) else {
                throw AudioEngineError.noPhysicalDeviceFound
            }
            do {
                try setupWithDevice(device)
                try start()
            } catch {
                // 释放半初始化的 AudioUnit，下次调用会重新创建，避免一直静音。
                cleanupFailedSetup()
                throw error
            }
            return
        }
        guard let unit = outputUnit else { return }
        if currentDeviceID == deviceID { return }

        // outputUnit 存在时引擎应处于运行状态（stop() 会直接释放 AudioUnit），
        // 因此切换后总是重新启动，不依赖切换前的运行状态。
        AudioOutputUnitStop(unit)

        // 切换设备
        var newDeviceID = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &newDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            // 不恢复旧设备：渲染器此时已读取新设备的共享内存，恢复会把音频送到旧显示器。
            // 直接释放 AudioUnit，下次调用重新创建。
            cleanupFailedSetup()
            throw AudioEngineError.deviceSwitchFailed(status)
        }

        // 输入格式固定为 48 kHz，设备采样率不同时由 AUHAL 转换，无需重设格式。
        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            cleanupFailedSetup()
            throw AudioEngineError.startFailed(startStatus)
        }
        currentDeviceID = deviceID
    }

    private func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        var newDeviceID = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &newDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioEngineError.setDeviceFailed(status)
        }
    }

    private func setFormat() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: Double(MoniVolConfig.defaultSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: MoniVolConfig.defaultChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        guard status == noErr else {
            throw AudioEngineError.setFormatFailed(status)
        }

        // Read back the actual format to confirm what the audio unit accepted.
        var actualFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let getStatus = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &actualFormat,
            &size
        )

        if getStatus == noErr {
            print("[AudioEngine] Stream format: \(actualFormat.mSampleRate) Hz, ch=\(actualFormat.mChannelsPerFrame), flags=0x\(String(actualFormat.mFormatFlags, radix: 16))")
        } else {
            logger.warning("Failed to read back stream format (OSStatus: \(getStatus))")
        }
    }

    private func setMaximumFramesPerSlice() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        var maximumFrames = Self.maximumFramesPerSlice
        let setStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard setStatus == noErr else {
            throw AudioEngineError.setMaximumFramesFailed(setStatus)
        }

        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let getStatus = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global,
            0,
            &maximumFrames,
            &dataSize
        )
        guard getStatus == noErr, maximumFrames > 0 else {
            throw AudioEngineError.setMaximumFramesFailed(getStatus)
        }

        renderer.prepare(
            maxFrames: maximumFrames,
            channelCount: MoniVolConfig.defaultChannels
        )
    }

    private func setRenderCallback() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        let rendererPtr = Unmanaged.passUnretained(renderer).toOpaque()

        var callbackStruct = AURenderCallbackStruct(
            inputProc: renderer.createRenderCallback(),
            inputProcRefCon: rendererPtr
        )

        let status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        guard status == noErr else {
            throw AudioEngineError.setCallbackFailed(status)
        }
    }

    private func initialize() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        let status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw AudioEngineError.initializationFailed(status)
        }
    }

}

enum AudioEngineError: Error, CustomStringConvertible {
    case componentNotFound
    case instanceCreationFailed(OSStatus)
    case unitNotInitialized
    case setDeviceFailed(OSStatus)
    case setFormatFailed(OSStatus)
    case setMaximumFramesFailed(OSStatus)
    case setCallbackFailed(OSStatus)
    case initializationFailed(OSStatus)
    case startFailed(OSStatus)
    case deviceSwitchFailed(OSStatus)
    case noPhysicalDeviceFound
    case noValidDeviceFound
    case allDevicesFailed

    var description: String {
        switch self {
        case .componentNotFound:
            return "HAL output component not found"
        case .instanceCreationFailed(let status):
            return "Failed to create audio unit instance (OSStatus: \(status))"
        case .unitNotInitialized:
            return "Audio unit not initialized"
        case .setDeviceFailed(let status):
            return "Failed to set output device (OSStatus: \(status))"
        case .setFormatFailed(let status):
            return "Failed to set stream format (OSStatus: \(status))"
        case .setMaximumFramesFailed(let status):
            return "Failed to configure maximum frames per slice (OSStatus: \(status))"
        case .setCallbackFailed(let status):
            return "Failed to set render callback (OSStatus: \(status))"
        case .initializationFailed(let status):
            return "Failed to initialize audio unit (OSStatus: \(status))"
        case .startFailed(let status):
            return "Failed to start audio unit (OSStatus: \(status))"
        case .deviceSwitchFailed(let status):
            return "Failed to switch device (OSStatus: \(status))"
        case .noPhysicalDeviceFound:
            return "No physical output device found in registry"
        case .noValidDeviceFound:
            return "No validated output devices available"
        case .allDevicesFailed:
            return "All available devices failed to initialize"
        }
    }
}
