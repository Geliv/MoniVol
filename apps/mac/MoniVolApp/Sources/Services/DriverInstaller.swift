import Foundation
@preconcurrency import AppKit

/// Driver installation states
enum DriverInstallState: Equatable {
    case notStarted
    case checkingExisting
    case copying
    case settingPermissions
    case restartingAudio
    case verifying
    case complete
    case failed(String)

    var isComplete: Bool {
        if case .complete = self {
            return true
        }
        return false
    }

    var isFailed: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var description: String {
        switch self {
        case .notStarted:
            return "Ready to install"
        case .checkingExisting:
            return "Checking for existing driver..."
        case .copying:
            return "Copying driver files..."
        case .settingPermissions:
            return "Setting permissions..."
        case .restartingAudio:
            return "Restarting audio system..."
        case .verifying:
            return "Verifying installation..."
        case .complete:
            return "Installation complete!"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }
}

/// Handles driver installation and verification
class DriverInstaller: ObservableObject {
    @Published var state: DriverInstallState = .notStarted
    @Published var progress: Double = 0.0

    private let driverName = "MoniVolDriver.driver"
    private let driverDestination = "/Library/Audio/Plug-Ins/HAL"

    /// Install the driver with progress updates
    func installDriver() async throws {
        await MainActor.run { state = .checkingExisting; progress = 0.1 }

        // Check if driver is already installed (fast file check)
        if isDriverInstalled() && !VersionManager.driverNeedsUpdate() {
            print("Driver already installed, skipping installation")
            await MainActor.run { state = .complete; progress = 1.0 }
            return
        }

        await MainActor.run { state = .copying; progress = 0.3 }

        // Find driver bundle in app resources
        guard let driverSource = findDriverBundle() else {
            throw DriverInstallError.driverNotFound
        }

        // Install driver with single admin prompt (copy + permissions + restart)
        try await installDriverWithPrivileges(from: driverSource)

        // Update progress through the stages
        await MainActor.run { state = .settingPermissions; progress = 0.5 }

        await MainActor.run { state = .restartingAudio; progress = 0.7 }

        // Wait for audio system to restart
        print("Waiting for audio system to restart...")
        try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second

        await MainActor.run { state = .verifying; progress = 0.9 }

        // Verify that the installed bundle is the version shipped by this App.
        let driverPath = "\(driverDestination)/\(driverName)"
        guard FileManager.default.fileExists(atPath: driverPath),
              let installedVersion = VersionManager.installedDriverVersion(),
              let bundledVersion = VersionManager.bundledDriverVersion(),
              VersionManager.areVersionsEqual(installedVersion, bundledVersion) else {
            throw DriverInstallError.verificationFailed
        }
        print("Driver verified: version \(installedVersion)")

        refreshControlCenter()

        await MainActor.run { state = .complete; progress = 1.0 }
        print("Driver installed successfully")
    }

    private func refreshControlCenter() {
        // coreaudiod 重启后，控制中心可能继续显示旧的输出设备列表。
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["ControlCenter"]

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                print("ControlCenter was not running or could not be refreshed")
            }
        } catch {
            print("Failed to refresh ControlCenter: \(error)")
        }
    }

    /// Check if driver is currently loaded
    func isDriverLoaded() -> Bool {
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

    /// Check if driver is installed (file exists)
    func isDriverInstalled() -> Bool {
        let driverPath = "\(driverDestination)/\(driverName)"
        return FileManager.default.fileExists(atPath: driverPath)
    }

    /// Find driver bundle in app resources
    private func findDriverBundle() -> String? {
        // For development: check if running from build directory
        if let bundlePath = Bundle.main.resourcePath {
            let driverPath = "\(bundlePath)/\(driverName)"
            if FileManager.default.fileExists(atPath: driverPath) {
                return driverPath
            }
        }

        // For production: driver should be in Resources
        if let resourcePath = Bundle.main.path(forResource: "MoniVolDriver", ofType: "driver") {
            return resourcePath
        }

        print("WARNING: Driver bundle not found in app resources")
        return nil
    }

    /// Install driver with single admin prompt (combines copy, permissions, and restart)
    private func installDriverWithPrivileges(from source: String) async throws {
        // Escape single quotes in paths for shell
        let escapedSource = source.replacingOccurrences(of: "'", with: "'\\''")
        let driverPath = "\(driverDestination)/\(driverName)"
        let escapedDriverPath = driverPath.replacingOccurrences(of: "'", with: "'\\''")
        let stagedDriverPath = "\(driverDestination)/.\(driverName).new"
        let escapedStagedDriverPath = stagedDriverPath.replacingOccurrences(of: "'", with: "'\\''")

        // Prepare the replacement beside the installed bundle first. The old
        // driver remains intact if copying or permission setup fails.
        let script = """
        do shell script "rm -rf '\(escapedStagedDriverPath)' && \
        cp -R '\(escapedSource)' '\(escapedStagedDriverPath)' && \
        chown -R root:wheel '\(escapedStagedDriverPath)' && \
        chmod -R 755 '\(escapedStagedDriverPath)' && \
        rm -rf '\(escapedDriverPath)' && \
        mv '\(escapedStagedDriverPath)' '\(escapedDriverPath)' && \
        killall coreaudiod" with administrator privileges
        """

        // Run AppleScript on background queue to avoid blocking UI
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let appleScript = NSAppleScript(source: script)
                var errorDict: NSDictionary?
                appleScript?.executeAndReturnError(&errorDict)

                if let errorDict = errorDict,
                   let errorMessage = errorDict["NSAppleScriptErrorMessage"] as? String {
                    print("Failed to install driver: \(errorMessage)")
                    continuation.resume(throwing: DriverInstallError.copyFailed(errorMessage))
                } else {
                    print("Driver installed and coreaudiod restarted")
                    continuation.resume()
                }
            }
        }
    }

    /// Copy driver using AppleScript with admin privileges
    @MainActor
    private func copyDriverWithPrivileges(from source: String) async throws {
        // Escape single quotes in paths for shell
        let escapedSource = source.replacingOccurrences(of: "'", with: "'\\''")
        let escapedDest = driverDestination.replacingOccurrences(of: "'", with: "'\\''")

        let script = "do shell script \"cp -R '\(escapedSource)' '\(escapedDest)/'\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)

        // Execute on main thread (AppleScript requires it)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let errorDict = errorDict,
           let errorMessage = errorDict["NSAppleScriptErrorMessage"] as? String {
            print("Failed to copy driver: \(errorMessage)")
            throw DriverInstallError.copyFailed(errorMessage)
        }
    }

    /// Set driver permissions using AppleScript
    @MainActor
    private func setDriverPermissions() async throws {
        let driverPath = "\(driverDestination)/\(driverName)"
        let escapedPath = driverPath.replacingOccurrences(of: "'", with: "'\\''")

        let script = "do shell script \"chown -R root:wheel '\(escapedPath)' && chmod -R 755 '\(escapedPath)'\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)

        // Execute on main thread (AppleScript requires it)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let errorDict = errorDict,
           let errorMessage = errorDict["NSAppleScriptErrorMessage"] as? String {
            print("Failed to set permissions: \(errorMessage)")
            throw DriverInstallError.permissionsFailed(errorMessage)
        }
    }

    /// Restart coreaudiod using AppleScript
    @MainActor
    private func restartAudio() async throws {
        let script = "do shell script \"killall coreaudiod\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)

        // Execute on main thread (AppleScript requires it)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let errorDict = errorDict,
           let errorMessage = errorDict["NSAppleScriptErrorMessage"] as? String {
            print("Failed to restart coreaudiod: \(errorMessage)")
            throw DriverInstallError.audioRestartFailed(errorMessage)
        }

        print("coreaudiod restarted")
    }

    /// Uninstall driver (for testing)
    func uninstallDriver() throws {
        let driverPath = "\(driverDestination)/\(driverName)"
        let escapedPath = driverPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "do shell script \"rm -rf '\(escapedPath)'\" with administrator privileges"

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        appleScript?.executeAndReturnError(&errorDict)

        if let errorDict = errorDict {
            let errorMessage = errorDict["NSAppleScriptErrorMessage"] as? String ?? "Unknown error"
            throw DriverInstallError.uninstallFailed(errorMessage)
        }

        print("Driver uninstalled")
    }
}

/// Driver installation errors
enum DriverInstallError: Error, LocalizedError {
    case driverNotFound
    case copyFailed(String)
    case permissionsFailed(String)
    case audioRestartFailed(String)
    case verificationFailed
    case uninstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .driverNotFound:
            return "Driver bundle not found in app resources"
        case .copyFailed(let message):
            return "Failed to copy driver: \(message)"
        case .permissionsFailed(let message):
            return "Failed to set permissions: \(message)"
        case .audioRestartFailed(let message):
            return "Failed to restart audio system: \(message)"
        case .verificationFailed:
            return "Driver installation could not be verified"
        case .uninstallFailed(let message):
            return "Failed to uninstall driver: \(message)"
        }
    }
}
