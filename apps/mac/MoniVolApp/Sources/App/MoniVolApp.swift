import SwiftUI
import Foundation
import Darwin
import AppKit
import CoreText
import CoreGraphics
import CoreAudio
import MoniVolCore
import os.log

// Main entry point - AppKit-based app with SwiftUI views
@main
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    var hostProcess: Process?
    var eventMonitor: EventMonitor?
    var onboardingCoordinator: OnboardingCoordinator?
    var driverUpdateWindow: DriverUpdateWindow?
    private var hostWatchdogTimer: DispatchSourceTimer?
    private var isTerminating = false
    private var isUpdatingDriver = false
    /// Set to true during uninstall so the Host watchdog does not relaunch it.
    var isUninstalling = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register custom font
        registerCustomFont()
        UpdateChecker.start()

        // Check if onboarding is needed
        if !OnboardingState.hasCompleted() {
            // Will switch to .regular in showOnboarding()
            showOnboarding()
            return
        }

        // Onboarding complete - run as menu bar app only
        NSApp.setActivationPolicy(.accessory)

        // Check for driver version mismatch (lazy update)
        checkDriverVersionMismatch()

        // Launch audio host if not already running
        startHostWatchdog()

        // Start IPC monitoring for device state updates from Host
        IPCController.shared.onDeviceStateChanged = { _ in
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
        }
        IPCController.shared.startMonitoring()

        // Retry proxy device binding after a short delay to handle the race
        // where Host hasn't created the proxy device yet at startup.
        // Run on background queue to avoid blocking main thread if CoreAudio HAL
        // is slow to respond (e.g. coreaudiod proxy system not ready).
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) {
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
        }

        // Set up menu bar UI
        setupMenuBar()
    }

    func checkDriverVersionMismatch() {
        // Only check if driver is already installed
        guard VersionManager.isDriverInstalled() else {
            print("Driver not installed - skipping version check")
            return
        }

        // Check for version mismatch
        if VersionManager.driverNeedsUpdate() {
            let installedVersion = VersionManager.installedDriverVersion() ?? "unknown"
            let bundledVersion = VersionManager.bundledDriverVersion() ?? "unknown"

            print("Driver version mismatch detected:")
            print("  Installed: \(installedVersion)")
            print("  Bundled: \(bundledVersion)")

            showDriverUpdatePrompt(
                currentVersion: installedVersion,
                newVersion: bundledVersion
            )
        } else {
            print("✓ Driver version is up to date")
        }
    }

    func showDriverUpdatePrompt(currentVersion: String, newVersion: String) {
        // Close existing window if any
        driverUpdateWindow?.close()

        // Create and show driver update window
        driverUpdateWindow = DriverUpdateWindow(
            currentVersion: currentVersion,
            newVersion: newVersion,
            onUpdate: { [weak self] in
                self?.performDriverUpdate()
            },
            onDismiss: { [weak self] in
                self?.driverUpdateWindow?.close()
                self?.driverUpdateWindow = nil
            }
        )

        driverUpdateWindow?.center()
        driverUpdateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func performDriverUpdate() {
        guard !isUpdatingDriver else { return }
        let language = AppLanguage.selected

        // Close the update window
        driverUpdateWindow?.close()
        driverUpdateWindow = nil
        isUpdatingDriver = true
        stopHostWatchdog()

        // Use existing DriverInstaller logic
        let installer = DriverInstaller()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.stopHostForDriverUpdate()

            do {
                try await installer.installDriver()
                print("✓ Driver updated successfully")

                if let bundledVersion = VersionManager.bundledDriverVersion() {
                    OnboardingState.updateLastDriverVersionCheck(bundledVersion)
                }
                self.finishDriverUpdate()

                // Show success alert
                let alert = NSAlert()
                let version = VersionManager.bundledDriverVersion()
                    ?? language.text("unknown", "未知")
                alert.messageText = language.text("Driver Updated", "驱动已更新")
                alert.informativeText = String(
                    format: language.text(
                        "The MoniVol audio driver has been updated to version %@.",
                        "MoniVol 音频驱动已更新至版本 %@。"
                    ),
                    version
                )
                alert.alertStyle = .informational
                alert.addButton(withTitle: language.text("OK", "好"))
                alert.runModal()
            } catch {
                print("Driver update failed: \(error)")
                self.finishDriverUpdate()

                let alert = NSAlert()
                alert.messageText = language.text("Update Failed", "更新失败")
                alert.informativeText = String(
                    format: language.text("Failed to update driver: %@", "更新驱动失败：%@"),
                    error.localizedDescription
                )
                alert.alertStyle = .critical
                alert.addButton(withTitle: language.text("OK", "好"))
                alert.runModal()
            }
        }
    }

    private func finishDriverUpdate() {
        VolumeController.shared.recoverAfterAudioSystemRestart()
        isUpdatingDriver = false
        startHostWatchdog()
    }

    func showOnboarding() {
        // Switch to regular activation policy to show window properly
        NSApp.setActivationPolicy(.regular)

        // Create and show onboarding
        onboardingCoordinator = OnboardingCoordinator()
        onboardingCoordinator?.show(onComplete: { [weak self] in
            print("Onboarding completion callback called")
            self?.startHostWatchdog()
            self?.setupMenuBar()
            // Retry proxy binding after host has time to start
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
                VolumeController.shared.refreshDeviceList()
                VolumeController.shared.findAndBindProxyDevice()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) {
                VolumeController.shared.refreshDeviceList()
                VolumeController.shared.findAndBindProxyDevice()
            }
            print("Host and menu bar setup complete")
        })

        print("Showing onboarding")
    }

    func setupMenuBar() {
        print("setupMenuBar() called")

        // Hide from Dock (menu bar only)
        NSApp.setActivationPolicy(.accessory)
        print("Activation policy set to .accessory")

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        print("Status bar item created: \(statusItem != nil)")

        if let button = statusItem?.button {
            // Load logo SVG and set as template for light/dark mode adaptation
            if let logoImage = loadLogoImage() {
                logoImage.isTemplate = true // Makes it adapt to light/dark mode
                button.image = logoImage
            } else {
                // Fallback to system icon if logo fails to load
                button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "MoniVol")
            }
            button.action = #selector(togglePopover)
            button.target = self
            print("Status bar button configured with waveform icon")
        } else {
            print("ERROR: Could not get status bar button!")
        }

        // Create popover with menu content
        popover = NSPopover()
        popover?.delegate = self
        popover?.behavior = .transient
        popover?.animates = false
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())

        // Set up event monitor to dismiss popover when clicking outside
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let popover = self?.popover, popover.isShown {
                self?.popover?.performClose(event)
            }
        }
        print("Menu bar setup complete - icon should be visible")
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        stopHostWatchdog()

        // If uninstalling, driver and host are already gone — skip heavy cleanup
        if isUninstalling {
            print("=== applicationWillTerminate (uninstall mode, skipping cleanup) ===")
            return
        }

        // 退出清理过程写入统一日志（默认级别会持久保存），保留期限由系统管理。
        let lifecycleLogger = Logger(subsystem: "com.monivol.app", category: "Lifecycle")
        func log(_ message: String) {
            lifecycleLogger.notice("\(message, privacy: .public)")
            print(message)
        }

        log("=== applicationWillTerminate CALLED ===")

        // Clean up CoreAudio listeners to prevent leaks
        VolumeController.shared.cleanup()

        // Stop IPC monitoring
        IPCController.shared.stopMonitoring()

        // Perform cleanup directly from the app
        performCleanup(logger: log)

        terminateHostAndProxies(logger: log)

        print("=== applicationWillTerminate COMPLETE ===")
    }

    /// Best-effort fallback to stop any running MoniVolHost even if we did not launch it.
    private func terminateHostAndProxies(logger: (String) -> Void) {
        if let process = hostProcess, process.isRunning {
            logger("Terminating tracked host process (pid \(process.processIdentifier))...")
            process.terminate()
            waitForProcessExit(process, timeout: 0.15, logger: logger)
            if process.isRunning {
                logger("Host still running, sending SIGKILL")
                kill(process.processIdentifier, SIGKILL)
            }
        }

        logger("Attempting best-effort shutdown of any remaining Host process")

        let pgrep = Process()
        pgrep.launchPath = "/usr/bin/pgrep"
        pgrep.arguments = ["-x", "MoniVolHost"]

        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = Pipe()

        do {
            try pgrep.run()
            pgrep.waitUntilExit()
        } catch {
            logger("Failed to run pgrep: \(error)")
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap({ Int32($0) }),
              !output.isEmpty else {
            logger("No additional MoniVolHost processes found")
            return
        }

        for pid in output {
            guard pid != getpid() else { continue }
            logger("Sending SIGTERM to MoniVolHost pid \(pid)")
            kill(pid, SIGTERM)
            if !waitForPIDExit(pid, timeout: 0.15) {
                logger("PID \(pid) still alive, sending SIGKILL")
                kill(pid, SIGKILL)
            }
        }

        // Remove any lingering shared memory/control files so the driver tears down proxies
        cleanupTempIPC(logger: logger)
    }

    /// Poll a Process for exit up to timeout seconds.
    private func waitForProcessExit(_ process: Process, timeout: TimeInterval, logger: (String) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            logger("Process \(process.processIdentifier) did not exit within \(timeout)s")
        }
    }

    /// Poll a PID for exit up to timeout seconds.
    private func waitForPIDExit(_ pid: Int32, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 {
                return true // no longer running
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return kill(pid, 0) != 0
    }

    /// Clean up temporary files that keep proxies alive.
    private func cleanupTempIPC(logger: (String) -> Void) {
        let fm = FileManager.default
        let controlFile = MonivolPaths.controlFile
        if fm.fileExists(atPath: controlFile) {
            logger("Removing control file \(controlFile)")
            unlink(controlFile)
        }

        // Remove shared memory files without deleting diagnostics or temp directories.
        if let tmpItems = try? fm.contentsOfDirectory(atPath: "/tmp") {
            for item in tmpItems where item.hasPrefix("monivol-") &&
                item != "monivol-devices.txt" &&
                item != "monivol-driver-debug.log" {
                let path = "/tmp/\(item)"
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else {
                    continue
                }
                logger("Removing shared memory file \(path)")
                unlink(path)
            }
        }
    }

    func performCleanup(logger: (String) -> Void = { print($0) }) {
        logger("[Cleanup] Starting cleanup process...")

        // 1. Restore default device to physical device (if currently on proxy)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var currentDeviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        if AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &currentDeviceID
        ) == noErr {
            // Get current device name
            if let name = DeviceQuery.name(currentDeviceID) {

                // If currently on a MoniVol proxy, switch back to physical device
                if name.contains(ProxyNaming.nameMarker) {
                    logger("[Cleanup] Currently on proxy device: \(name)")

                    // Get proxy UID
                    if let proxyUIDStr = DeviceQuery.uid(currentDeviceID) {

                        // Extract physical device UID (remove "-monivol" suffix)
                        if let physicalUID = ProxyNaming.physicalUID(from: proxyUIDStr) {
                            logger("[Cleanup] Looking for physical device with UID: \(physicalUID)")

                            // Find the physical device
                            if let physicalDeviceID = findDeviceByUID(physicalUID) {
                                logger("[Cleanup] Restoring default device to physical device (ID: \(physicalDeviceID))")

                                var newDeviceID = physicalDeviceID
                                let result = AudioObjectSetPropertyData(
                                    AudioObjectID(kAudioObjectSystemObject),
                                    &propertyAddress,
                                    0,
                                    nil,
                                    UInt32(MemoryLayout<AudioDeviceID>.size),
                                    &newDeviceID
                                )

                                // Also restore system output device
                                var systemAddress = AudioObjectPropertyAddress(
                                    mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                    mScope: kAudioObjectPropertyScopeGlobal,
                                    mElement: kAudioObjectPropertyElementMain
                                )
                                var systemDeviceID = physicalDeviceID
                                AudioObjectSetPropertyData(
                                    AudioObjectID(kAudioObjectSystemObject),
                                    &systemAddress,
                                    0,
                                    nil,
                                    UInt32(MemoryLayout<AudioDeviceID>.size),
                                    &systemDeviceID
                                )

                                if result == noErr {
                                    logger("[Cleanup] Restored to physical device")
                                    // CoreAudio device switch is synchronous, no sleep needed
                                } else {
                                    logger("[Cleanup] WARNING: Failed to restore device (error \(result))")
                                }
                            } else {
                                logger("[Cleanup] WARNING: Could not find physical device with UID: \(physicalUID)")
                            }
                        }
                    }
                } else {
                    logger("[Cleanup] Already on physical device: \(name)")
                }
            }
        }

        // 2. Remove control file - driver will detect and remove proxies
        let controlFilePath = MonivolPaths.controlFile
        logger("[Cleanup] Removing control file: \(controlFilePath)")
        unlink(controlFilePath)

        // 3. Wait for driver to remove devices (driver polls every 100ms)
        logger("[Cleanup] Waiting for driver to remove proxy devices...")
        Thread.sleep(forTimeInterval: 0.5)

        logger("[Cleanup] Cleanup complete")
    }

    func findDeviceByUID(_ targetUID: String) -> AudioDeviceID? {
        DeviceQuery.findDeviceID(byUID: targetUID)
    }

    func checkAndLoadDriverIfNeeded() {
        // Check if MoniVol driver is already loaded
        if isDriverLoaded() {
            print("MoniVol driver already loaded, no need to restart coreaudiod")
            return
        }

        print("WARNING: MoniVol driver not detected, attempting to load...")

        // Check if driver is installed
        let driverPath = "/Library/Audio/Plug-Ins/HAL/MoniVolDriver.driver"
        guard FileManager.default.fileExists(atPath: driverPath) else {
            showAlert(
                "Driver Not Installed",
                "MoniVol driver is not installed at \(driverPath)\n\nInstall it with:\ncd packages/driver && ./install.sh && sudo killall coreaudiod"
            )
            return
        }

        // Attempt to restart coreaudiod
        // This uses AppleScript to request admin privileges
        let script = """
        do shell script "killall coreaudiod" with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error = error {
            print("Failed to restart coreaudiod: \(error)")
            showAlert("Driver Load Failed", "Could not restart coreaudiod. You may need to manually run:\nsudo killall coreaudiod")
        } else {
            print("coreaudiod restarted successfully")
            // Wait a bit for coreaudiod to restart
            Thread.sleep(forTimeInterval: 2.0)
        }
    }

    func isDriverLoaded() -> Bool {
        // Use system_profiler to check if MoniVol devices are visible
        let task = Process()
        task.launchPath = "/usr/sbin/system_profiler"
        task.arguments = ["SPAudioDataType"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                return output.contains("MoniVol")
            }
        } catch {
            print("Failed to check driver status: \(error)")
        }

        return false
    }

    func launchHostIfNeeded() {
        guard !isTerminating, !isUninstalling, !isUpdatingDriver else { return }

        if let process = hostProcess, process.isRunning {
            return
        }

        // An existing Host may have survived an App restart. Match the exact
        // process name so unrelated command lines containing "MoniVolHost"
        // cannot suppress startup.
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "MoniVolHost"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Failed to check MoniVolHost status: \(error)")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if output.isEmpty {
            // Host not running, launch it
            print("Launching MoniVolHost...")
            startHost()
        } else {
            print("MoniVolHost already running (PID: \(output))")
        }
    }

    private func startHostWatchdog() {
        guard hostWatchdogTimer == nil, !isUpdatingDriver else { return }

        launchHostIfNeeded()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5.0, repeating: 5.0, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.launchHostIfNeeded()
        }
        hostWatchdogTimer = timer
        timer.resume()
    }

    private func stopHostWatchdog() {
        hostWatchdogTimer?.cancel()
        hostWatchdogTimer = nil
    }

    @MainActor
    private func stopHostForDriverUpdate() async {
        let pids = runningHostProcessIDs()
        guard !pids.isEmpty else {
            cleanupTempIPC(logger: { print($0) })
            hostProcess = nil
            return
        }

        for pid in pids {
            print("Stopping MoniVolHost for driver update (pid \(pid))...")
            kill(pid, SIGUSR1)
        }

        let deadline = Date().addingTimeInterval(3.0)
        var remaining = pids
        while !remaining.isEmpty && Date() < deadline {
            remaining.removeAll { kill($0, 0) != 0 }
            if !remaining.isEmpty {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }

        for pid in remaining {
            print("MoniVolHost did not exit cleanly; sending SIGKILL to pid \(pid)")
            kill(pid, SIGKILL)
        }
        if !remaining.isEmpty {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        cleanupTempIPC(logger: { print($0) })
        hostProcess = nil
    }

    private func runningHostProcessIDs() -> [Int32] {
        let task = Process()
        task.launchPath = "/usr/bin/pgrep"
        task.arguments = ["-x", "MoniVolHost"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            print("Failed to enumerate MoniVolHost processes: \(error)")
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n")
            .compactMap { Int32($0) } ?? []
    }

    func startHost() {
        // Find the host executable - try multiple possible locations
        let fileManager = FileManager.default
        var possiblePaths: [String] = []

        // PRIORITY 1: Check for auxiliary executable in .app bundle (production)
        if let helperURL = Bundle.main.url(forAuxiliaryExecutable: "MoniVolHost") {
            possiblePaths.append(helperURL.path)
        }

        // PRIORITY 2: Check for embedded binary in MacOS directory (for distribution)
        if let executablePath = Bundle.main.executableURL?.deletingLastPathComponent().path {
            let embeddedHost = "\(executablePath)/MoniVolHost"
            possiblePaths.append(embeddedHost)
        }

        // PRIORITY 3: Check Contents/Helpers/ directory
        if let bundlePath = Bundle.main.bundlePath as String? {
            possiblePaths.append("\(bundlePath)/Contents/Helpers/MoniVolHost")
        }

        #if DEBUG
        // Development builds - relative to app bundle
        var possibleBasePaths: [String] = []

        if let appPath = Bundle.main.bundlePath as String? {
            // If running from Xcode/build, go up to project root
            let appURL = URL(fileURLWithPath: appPath)
            if appPath.contains("/MoniVolApp/") {
                let projectRoot = appURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                possibleBasePaths.append(projectRoot.path)
            }
        }

        // Try current working directory
        if let cwd = fileManager.currentDirectoryPath as String? {
            possibleBasePaths.append(cwd)
        }

        // Try home directory
        if let homeDir = ProcessInfo.processInfo.environment["HOME"] {
            possibleBasePaths.append("\(homeDir)/monivol")
        }

        // Build development paths
        for basePath in possibleBasePaths {
            // Try release build (with architecture subdirectory)
            if let arch = getArchitecture() {
                possiblePaths.append("\(basePath)/packages/host/.build/\(arch)/release/MoniVolHost")
            }
            possiblePaths.append("\(basePath)/packages/host/.build/release/MoniVolHost")
            // Try debug build
            if let arch = getArchitecture() {
                possiblePaths.append("\(basePath)/packages/host/.build/\(arch)/debug/MoniVolHost")
            }
            possiblePaths.append("\(basePath)/packages/host/.build/debug/MoniVolHost")
        }

        // Also try absolute path based on current user
        if let homeDir = ProcessInfo.processInfo.environment["HOME"] {
            if let arch = getArchitecture() {
                possiblePaths.append("\(homeDir)/monivol/packages/host/.build/\(arch)/release/MoniVolHost")
            }
            possiblePaths.append("\(homeDir)/monivol/packages/host/.build/release/MoniVolHost")
        }

        // Try environment variable if set
        if let monivolRoot = ProcessInfo.processInfo.environment["MONIVOL_ROOT"] {
            if let arch = getArchitecture() {
                possiblePaths.append("\(monivolRoot)/packages/host/.build/\(arch)/release/MoniVolHost")
            }
            possiblePaths.append("\(monivolRoot)/packages/host/.build/release/MoniVolHost")
        }
        #endif

        guard let hostPath = possiblePaths.first(where: { fileManager.fileExists(atPath: $0) }) else {
            print("ERROR: Could not find MoniVolHost executable")
            print("Searched in:")
            for path in possiblePaths {
                print("  - \(path)")
            }
            showAlert("MoniVol Host Not Found", "Please build the host first:\ncd packages/host && swift build -c release")
            return
        }

        let process = Process()
        process.launchPath = hostPath
        process.arguments = []

        // The App has no consumer for helper stdout/stderr. Sending them to a
        // pipe would eventually block a long-running Host once the pipe fills.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self = self else { return }
                print("MoniVolHost terminated (status: \(process.terminationStatus), reason: \(process.terminationReason.rawValue))")
                if self.hostProcess === process {
                    self.hostProcess = nil
                }
                if !self.isTerminating && !self.isUninstalling && !self.isUpdatingDriver {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.launchHostIfNeeded()
                    }
                }
            }
        }

        do {
            try process.run()
            hostProcess = process
            print("Started MoniVolHost at: \(hostPath)")
        } catch {
            hostProcess = nil
            print("Failed to launch host: \(error)")
            showAlert("Failed to Launch Host", error.localizedDescription)
        }
    }

    func getArchitecture() -> String? {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &machine, &size, nil, 0)
        let arch = String(cString: machine)

        // Map to SwiftPM architecture names
        if arch.contains("arm64") {
            return "arm64-apple-macosx"
        } else if arch.contains("x86_64") {
            return "x86_64-apple-macosx"
        }
        return nil
    }

    func loadLogoImage() -> NSImage? {
        let fileManager = FileManager.default
        var logoURL: URL?

        // PRIORITY 1: Try using Bundle's resource API (works across bundle structures)
        // First try to find the resource bundle
        if let resourceBundleURL = Bundle.main.url(forResource: "MoniVolApp_MoniVolApp", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let logoPath = resourceBundle.url(forResource: "icons/monivol-menu", withExtension: "svg") {
            print("Found menu icon via resource bundle API: \(logoPath.path)")
            logoURL = logoPath
        }

        // PRIORITY 2: Try SwiftPM resource bundle (production builds)
        // SwiftPM creates a separate bundle named "<Target>_<Target>.bundle"
        if logoURL == nil, let executableURL = Bundle.main.executableURL {
            let bundleName = "MoniVolApp_MoniVolApp.bundle"
            let resourceBundleURL = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName)
                .appendingPathComponent("Resources/icons/monivol-menu.svg")

            if fileManager.fileExists(atPath: resourceBundleURL.path) {
                print("Found logo in SwiftPM bundle: \(resourceBundleURL.path)")
                logoURL = resourceBundleURL
            }
        }

        // PRIORITY 3: Try main bundle's built-in resource lookup
        if logoURL == nil, let mainBundleURL = Bundle.main.url(forResource: "icons/monivol-menu", withExtension: "svg") {
            print("Found menu icon via main bundle: \(mainBundleURL.path)")
            logoURL = mainBundleURL
        }

        // PRIORITY 4: Try main bundle resources (alternative bundle structure)
        if logoURL == nil, let resourcePath = Bundle.main.resourcePath {
            let possiblePaths = [
                "\(resourcePath)/Resources/icons/monivol-menu.svg",
                "\(resourcePath)/icons/monivol-menu.svg"
            ]

            for path in possiblePaths {
                if fileManager.fileExists(atPath: path) {
                    print("Found logo in main bundle: \(path)")
                    logoURL = URL(fileURLWithPath: path)
                    break
                }
            }
        }

        // PRIORITY 5: Development - relative to executable
        if logoURL == nil, let executablePath = Bundle.main.executablePath {
            let executableDir = (executablePath as NSString).deletingLastPathComponent
            let sourcePath = (executableDir as NSString).appendingPathComponent("../../../Sources/Resources/icons/monivol-menu.svg")
            let normalizedPath = (sourcePath as NSString).standardizingPath
            if fileManager.fileExists(atPath: normalizedPath) {
                print("Found logo in development Sources: \(normalizedPath)")
                logoURL = URL(fileURLWithPath: normalizedPath)
            }
        }

        // PRIORITY 6: Development - absolute path from repo root
        if logoURL == nil {
            let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? ""
            let absolutePath = "\(homeDir)/monivol/apps/mac/MoniVolApp/Sources/Resources/icons/monivol-menu.svg"
            if fileManager.fileExists(atPath: absolutePath) {
                print("Found menu icon at absolute path: \(absolutePath)")
                logoURL = URL(fileURLWithPath: absolutePath)
            }
        }

        guard let url = logoURL else {
            print("Failed to find monivol-menu.svg in any location")
            return nil
        }

        // Load SVG (NSImage supports SVG on macOS 10.15+)
        guard let image = NSImage(contentsOf: url) else {
            print("Failed to load image from: \(url.path)")
            return nil
        }

        // Resize to appropriate menu bar size (typically 18-22px)
        let size = NSSize(width: 16, height: 16)
        let resizedImage = NSImage(size: size)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)
        resizedImage.unlockFocus()

        print("Successfully loaded and resized logo")
        return resizedImage
    }

    func registerCustomFont() {
        let fileManager = FileManager.default
        var fontURL: URL?

        // PRIORITY 1: Try using Bundle's resource API (works across bundle structures)
        if let resourceBundleURL = Bundle.main.url(forResource: "MoniVolApp_MoniVolApp", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let fontPath = resourceBundle.url(forResource: "fonts/SignPainterHouseScript", withExtension: "ttf") {
            print("Found font via resource bundle API: \(fontPath.path)")
            fontURL = fontPath
        }

        // PRIORITY 2: Try SwiftPM resource bundle (production builds)
        if fontURL == nil, let executableURL = Bundle.main.executableURL {
            let bundleName = "MoniVolApp_MoniVolApp.bundle"
            let resourceBundleURL = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName)
                .appendingPathComponent("Resources/fonts/SignPainterHouseScript.ttf")

            if fileManager.fileExists(atPath: resourceBundleURL.path) {
                print("Found font in SwiftPM bundle: \(resourceBundleURL.path)")
                fontURL = resourceBundleURL
            }
        }

        // PRIORITY 3: Try main bundle's built-in resource lookup
        if fontURL == nil, let mainBundleURL = Bundle.main.url(forResource: "fonts/SignPainterHouseScript", withExtension: "ttf") {
            print("Found font via main bundle: \(mainBundleURL.path)")
            fontURL = mainBundleURL
        }

        // PRIORITY 4: Try main bundle resources (alternative bundle structure)
        if fontURL == nil, let resourcePath = Bundle.main.resourcePath {
            let possiblePaths = [
                "\(resourcePath)/Resources/fonts/SignPainterHouseScript.ttf",
                "\(resourcePath)/fonts/SignPainterHouseScript.ttf"
            ]

            for path in possiblePaths {
                if fileManager.fileExists(atPath: path) {
                    print("Found font in main bundle: \(path)")
                    fontURL = URL(fileURLWithPath: path)
                    break
                }
            }
        }

        // PRIORITY 5: Development - relative to executable
        if fontURL == nil, let executablePath = Bundle.main.executablePath {
            let executableDir = (executablePath as NSString).deletingLastPathComponent
            let sourcePath = (executableDir as NSString).appendingPathComponent("../../../Sources/Resources/fonts/SignPainterHouseScript.ttf")
            let normalizedPath = (sourcePath as NSString).standardizingPath
            if fileManager.fileExists(atPath: normalizedPath) {
                print("Found font in development Sources: \(normalizedPath)")
                fontURL = URL(fileURLWithPath: normalizedPath)
            }
        }

        // PRIORITY 6: Development - absolute path from repo root
        if fontURL == nil {
            let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? ""
            let absolutePath = "\(homeDir)/monivol/apps/mac/MoniVolApp/Sources/Resources/fonts/SignPainterHouseScript.ttf"
            if fileManager.fileExists(atPath: absolutePath) {
                print("Found font at absolute path: \(absolutePath)")
                fontURL = URL(fileURLWithPath: absolutePath)
            }
        }

        guard let url = fontURL else {
            print("Failed to find SignPainterHouseScript.ttf in any location")
            return
        }

        var error: Unmanaged<CFError>?
        let result = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)

        if result {
            print("Successfully registered custom font")
        } else if let error = error {
            print("Failed to register font: \(error.takeRetainedValue())")
        }
    }

    func showAlert(_ title: String, _ message: String) {
        let language = AppLanguage.selected
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: language.text("OK", "好"))
        alert.runModal()
    }

    func popoverDidClose(_ notification: Notification) {
        // 点击外部、按 Escape 或主动关闭时，都释放全局事件监听。
        eventMonitor?.stop()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                // Core Audio 重启或设备切换后，先读取当前输出再展示弹窗。
                VolumeController.shared.refreshDeviceList()
                VolumeController.shared.findAndBindProxyDevice()
                // Position the popover directly below the menu bar button
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

                // Make popover window key immediately for proper glass effect
                if let popoverWindow = popover.contentViewController?.view.window {
                    popoverWindow.makeKeyAndOrderFront(nil)
                }

                // On macOS 15+ (Tahoe/Sequoia), NSPopover positioning can be off on external
                // monitors. Manually reposition if needed.
                if #available(macOS 15.0, *) {
                    if let popoverWindow = popover.contentViewController?.view.window,
                       let buttonWindow = button.window {
                        let buttonScreenFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                        let popoverFrame = popoverWindow.frame

                        // Calculate where the popover should be: directly below the button
                        let targetY = buttonScreenFrame.minY - popoverFrame.height

                        // Only adjust if there's a significant gap (more than 10 pixels)
                        if abs(popoverFrame.maxY - buttonScreenFrame.minY) > 10 {
                            popoverWindow.setFrameOrigin(NSPoint(x: popoverFrame.origin.x, y: targetY))
                        }
                    }
                }

                eventMonitor?.start()
            }
        }
    }
}

// EventMonitor to detect clicks outside the popover
class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// Main entry point - check for command-line flags before launching app
extension AppDelegate {
    static func main() {
        // Check for --reset-onboarding flag
        if CommandLine.arguments.contains("--reset-onboarding") {
            OnboardingState.reset()
            print("Onboarding reset - will show on next launch")
        }

        // Launch the app
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
