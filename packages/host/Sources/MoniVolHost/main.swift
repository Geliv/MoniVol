import AudioToolbox
import CMoniVolAudio
import CoreAudio
import Darwin
import Foundation
import MoniVolCore
import os.log

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

private let logger = Logger(subsystem: "com.monivol.host", category: "Main")
private var signalSources: [DispatchSourceSignal] = []
// 持有 beginActivity 返回的 token，activity 持续到进程退出。
private var processActivity: NSObjectProtocol?

let deviceDiscovery = DeviceDiscovery()
let deviceRegistry = DeviceRegistry()
let memoryManager = SharedMemoryManager()
let volumePersistence = VolumePersistence()
let proxyManager = ProxyDeviceManager(registry: deviceRegistry, volumePersistence: volumePersistence)
let renderer = AudioRenderer()
let audioEngine = AudioEngine(renderer: renderer, registry: deviceRegistry)
let deviceMonitor = DeviceMonitor(
    registry: deviceRegistry,
    proxyManager: proxyManager,
    memoryManager: memoryManager,
    discovery: deviceDiscovery,
    audioEngine: audioEngine
)
let sleepWakeMonitor = SleepWakeMonitor()

func main() {
    proxyManager.onActiveProxyChanged = { uid in
        memoryManager.withMemory(for: uid) { memory in
            renderer.setSharedMemory(memory)
        }
    }
    memoryManager.onWillUnmap = { memory in
        renderer.clearSharedMemory(memory)
    }
    memoryManager.onMemoryCreated = { uid, memory in
        if proxyManager.activeProxyUID == uid {
            renderer.setSharedMemory(memory)
        }
    }

    setupSignalHandlers()
    logger.info("Signal handlers installed")

    // Prevent macOS App Nap from throttling this process.
    // Without this, the system may suspend timers and background work
    // after prolonged playback, causing heartbeat timeouts and audio dropout.
    // .userInitiated 会禁止系统空闲睡眠，Host 常驻时不能使用。
    processActivity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
        reason: "MoniVol realtime audio processing"
    )

    print("[Step 0] Setting up directories...")
    do {
        try PathManager.ensureDirectories()
        print("    ✓ Application Support: \(PathManager.appSupportDir.path)")
        print("    ✓ Logs: \(PathManager.logsDir.path)")
    } catch {
        logger.error("Failed to create directories: \(error.localizedDescription)")
        exit(1)
    }

    print("[Step 1] Discovering physical audio devices...")
    let devices = deviceDiscovery.enumeratePhysicalDevices()

    let displayDevices = devices.filter { $0.needsDisplayProxy }
    logger.info("Found \(displayDevices.count) external display audio device(s) requiring volume control")
    for device in displayDevices {
        let status = device.validationPassed ? "✓" : "⚠"
        var line = "    \(status) \(device.name) (\(device.uid))"
        if let note = device.validationNote {
            line += " - \(note)"
        }
        print(line)
    }

    print("[Step 2] Registering device change listeners...")
    deviceMonitor.registerListeners()

    print("[Step 3] Creating shared memory files...")
    memoryManager.createMemory(for: displayDevices)

    print("[Step 4] Writing control file...")
    deviceRegistry.update(displayDevices)
    print("    ✓ Control file: \(MoniVolConfig.controlFilePath)")

    print("[Step 5] Starting heartbeat monitor...")
    memoryManager.startHeartbeat()

    print("[Step 6] Waiting for driver to create proxy devices...")
    if let selectedDisplay = proxyManager.resolveCurrentOutputDevice(in: displayDevices)
        ?? displayDevices.first(where: { $0.uid == proxyManager.preferredDisplayUID }) {
        let deadline = Date().addingTimeInterval(MoniVolConfig.deviceWaitTimeout)
        while Date() < deadline && proxyManager.findProxyDevice(forPhysicalUID: selectedDisplay.uid) == nil {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    print("[Step 7] Auto-selecting proxy device...")
    proxyManager.autoSelectProxy(
        fallbackDeviceID: devices.first(where: { $0.transportType == kAudioDeviceTransportTypeBuiltIn })?.id
    )

    // Bounce device to recapture audio from apps that were already running
    if proxyManager.activeProxyDeviceID != 0 {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) {
            proxyManager.bounceDevice()
        }
    }

    print("[Step 7.5] Registering sleep/wake handler...")
    sleepWakeMonitor.onSleep = {
        print("[SleepWake] System entering sleep, stopping AudioEngine...")
        audioEngine.stop()
        logger.info("AudioEngine stopped before sleep")
    }
    sleepWakeMonitor.onWake = {
        print("[SleepWake] Recovering after wake...")
        deviceMonitor.reregisterListeners()
        deviceMonitor.resetDebounce()
        proxyManager.reregisterVolumeForwarding()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard proxyManager.activePhysicalDeviceID != 0 else { return }
            do {
                try audioEngine.switchDevice(proxyManager.activePhysicalDeviceID)
                logger.info("AudioEngine restarted after wake")
            } catch {
                logger.error("AudioEngine restart failed: \(error.localizedDescription)")
            }
        }
    }
    sleepWakeMonitor.start()

    print("[Step 8] Setting up audio engine with device fallback...")

    // Only run the forwarding engine while a display proxy is selected.
    let preferredDeviceID = proxyManager.activePhysicalDeviceID
    if preferredDeviceID != 0 {
      do {
        try audioEngine.switchDevice(preferredDeviceID)
        logger.info("Audio engine started successfully")

        // Post-start volume sync: After IO starts, the driver maps shared memory.
        // Re-apply the current proxy volume so the driver writes it into shared memory.
        // Without this, shared memory retains its init default (0.35) instead of the
        // actual volume set during restoreVolumeState (before IO was running).
        if proxyManager.activeProxyDeviceID != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let physicalUID = proxyManager.activeProxyUID {
                    proxyManager.restoreVolumeState(
                        proxyDeviceID: proxyManager.activeProxyDeviceID,
                        physicalUID: physicalUID
                    )
                    logger.info("Volume re-synced to shared memory")
                }
            }
        }
      } catch {
        logger.error("Audio engine setup failed: \(error.localizedDescription)")
      }
    }

    // Listen for bounce requests from App via Darwin notification
    var bounceToken: Int32 = 0
    let bounceStatus = _notify_register_dispatch(
        MonivolNotifications.bounceRequest,
        &bounceToken,
        DispatchQueue.global(qos: .userInitiated)
    ) { _ in
        logger.info("Received bounce request from App")
        proxyManager.bounceDevice()
    }
    if bounceStatus != 0 {
        logger.error("Failed to register bounce notification listener (status: \(bounceStatus))")
    }

    RunLoop.current.run()
}

func setupSignalHandlers() {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGUSR1, SIG_IGN)

    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigintSource.setEventHandler {
        print("\n[Signal] Received SIGINT (Ctrl+C)")
        cleanup()
        exit(0)
    }
    sigintSource.resume()
    signalSources.append(sigintSource)

    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigtermSource.setEventHandler {
        print("\n[Signal] Received SIGTERM")
        cleanup()
        exit(0)
    }
    sigtermSource.resume()
    signalSources.append(sigtermSource)

    let driverUpdateSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    driverUpdateSource.setEventHandler {
        print("\n[Signal] Preparing for driver update")
        cleanup(restartAudioSystem: false)
        exit(0)
    }
    driverUpdateSource.resume()
    signalSources.append(driverUpdateSource)
}

func cleanup(restartAudioSystem: Bool = true) {
    print("\n[Cleanup] Starting cleanup process...")

    sleepWakeMonitor.stop()
    memoryManager.stopHeartbeat()
    deviceMonitor.stopListening()

    _ = proxyManager.restorePhysicalDevice()

    audioEngine.stop()

    print("[Cleanup] Removing control file...")
    unlink(MoniVolConfig.controlFilePath)

    Thread.sleep(forTimeInterval: MoniVolConfig.cleanupWaitTimeout)

    memoryManager.cleanup()

    if restartAudioSystem {
        restartCoreAudio()
    }

    logger.info("Cleanup complete")
}

private func restartCoreAudio() {
    // Force HAL to drop any lingering virtual devices by restarting coreaudiod
    let task = Process()
    task.launchPath = "/usr/bin/killall"
    task.arguments = ["coreaudiod"]  // 默认发送 SIGTERM

    do {
        try task.run()
        task.waitUntilExit()
        logger.info("Restarted coreaudiod (status \(task.terminationStatus))")
    } catch {
        logger.error("Failed to restart coreaudiod: \(error.localizedDescription)")
    }
}

main()
