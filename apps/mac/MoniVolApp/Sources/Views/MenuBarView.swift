import SwiftUI
import AppKit

// Cache font lookup once at launch
private let monivolFont: Font = {
    let size: CGFloat = 22
    let possibleNames = [
        "SignPainterHouseScript",
        "SignPainter-HouseScript",
        "SignPainter House Script",
        "SignPainter"
    ]
    for name in possibleNames {
        if NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
    }
    return .system(size: size, weight: .bold)
}()

struct MenuBarView: View {
    @StateObject private var volumeController = VolumeController.shared

    var body: some View {
        VStack(spacing: 0) {
            // 1. Active device
            DeviceHeader(deviceName: volumeController.activeDeviceName)

            Divider()
                .padding(.horizontal, 12)

            // 2. Volume slider (only for fixed-volume devices)
            if volumeController.isFixedVolumeDevice {
                VolumeSliderRow(
                    volume: Binding(
                        get: { volumeController.currentVolume },
                        set: { volumeController.setVolume($0) }
                    ),
                    isMuted: volumeController.isMuted,
                    onToggleMute: {
                        volumeController.setMute(!volumeController.isMuted)
                    }
                )
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            } else {
                Text("This device supports native volume control")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }

            Divider()
                .padding(.horizontal, 12)

            // 3. Device list
            DeviceListSection(
                devices: volumeController.allDevices,
                activeUID: volumeController.activeDeviceUID,
                onSelect: { device in
                    volumeController.switchDevice(to: device)
                }
            )

            // 4. Reconnect audio, update check + Footer
            ReconnectAudioButton()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            CheckForUpdatesButton()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            FooterBar()
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Device Header

struct DeviceHeader: View {
    let deviceName: String

    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text(deviceName.isEmpty ? "No Device" : deviceName)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - Volume Slider

struct VolumeSliderRow: View {
    @Binding var volume: Float
    let isMuted: Bool
    let onToggleMute: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggleMute) {
                Image(systemName: muteIcon)
                    .font(.system(size: 12))
                    .foregroundColor(isMuted ? .red : .secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)

            Slider(value: Binding(
                get: { Double(volume) },
                set: { volume = Float($0) }
            ), in: 0...1)

            Text("\(Int(volume * 100))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }

    private var muteIcon: String {
        if isMuted || volume <= 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - Device List

struct DeviceListSection: View {
    let devices: [OutputDevice]
    let activeUID: String
    let onSelect: (OutputDevice) -> Void

    private let maxVisibleDevices = 8
    private let rowHeight: CGFloat = 28
    private let rowSpacing: CGFloat = 2
    private let verticalPadding: CGFloat = 6

    var body: some View {
        if devices.count > maxVisibleDevices {
            ScrollView(.vertical) {
                deviceRows
            }
            .frame(height: CGFloat(maxVisibleDevices) * rowHeight
                + CGFloat(maxVisibleDevices - 1) * rowSpacing
                + verticalPadding * 2)
        } else {
            deviceRows
        }
    }

    private var deviceRows: some View {
        VStack(spacing: rowSpacing) {
            ForEach(devices) { device in
                DeviceRow(
                    device: device,
                    isActive: device.uid == activeUID,
                    onSelect: { onSelect(device) }
                )
                .frame(height: rowHeight)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, verticalPadding)
    }
}

struct DeviceRow: View {
    let device: OutputDevice
    let isActive: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundColor(isActive ? .accentColor : .secondary)

                Text(device.name)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if device.isFixedVolume {
                    Text("Fixed")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.15))
                        .cornerRadius(3)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}

// MARK: - Reconnect Audio

struct ReconnectAudioButton: View {
    @State private var isBouncing = false
    @State private var showDone = false

    var body: some View {
        Button(action: reconnect) {
            HStack(spacing: 6) {
                if isBouncing {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: showDone ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundColor(showDone ? .green : .secondary)
                }
                Text(showDone ? "Reconnected" : "Reconnect Audio")
                    .font(.system(size: 11))
                    .foregroundColor(showDone ? .green : .primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .disabled(isBouncing)
    }

    private func reconnect() {
        isBouncing = true
        VolumeController.shared.bounceDevice()
        // Show feedback after bounce completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isBouncing = false
            showDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showDone = false
            }
        }
    }
}

// MARK: - Footer

struct CheckForUpdatesButton: View {
    @State private var isChecking = false

    var body: some View {
        Button {
            isChecking = true
            Task { @MainActor in
                await UpdateChecker.checkForUpdates()
                isChecking = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                Text(isChecking ? "Checking for Updates..." : "Check for Updates")
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.1))
            )
        }
        .buttonStyle(.plain)
        .disabled(isChecking)
    }
}

struct FooterBar: View {
    var body: some View {
        HStack(spacing: 8) {
            UninstallButton()
            Spacer()
            QuitButton()
        }
    }
}

struct UninstallButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: performUninstall) {
            Text("Uninstall Driver")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(isHovered ? .white : .red.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.red : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }

    private func performUninstall() {
        let alert = NSAlert()
        alert.messageText = "Uninstall MoniVol Driver"
        alert.informativeText = "This will remove the audio driver, stop background processes, and clear configuration data. The app itself will not be deleted — you can reinstall the driver anytime."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall Driver")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Tell AppDelegate we're uninstalling so Host's terminationHandler
        // won't call NSApp.terminate prematurely.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.isUninstalling = true
        }

        // Step 1: Kill host and remove driver (requires admin).
        // Each command is guarded with "|| true" so a single failure
        // (e.g. coreaudiod restart returning non-zero) does not abort
        // the entire script and cause the app to skip cleanup.
        let script = """
        do shell script "killall MoniVolHost SoundBridgeHost 2>/dev/null || true; \
        rm -rf /Library/Audio/Plug-Ins/HAL/MoniVolDriver.driver /Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver || true; \
        rm -f /tmp/monivol-devices.txt 2>/dev/null || true; \
        rm -f /tmp/monivol-* 2>/dev/null || true; \
        killall coreaudiod 2>/dev/null || true" with administrator privileges
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        // Proceed with user-level cleanup regardless of AppleScript result.
        // The admin script may report an error even when it partially succeeded
        // (e.g. coreaudiod restart returns non-zero), so we always clean up.

        // Clean up Application Support data
        let fm = FileManager.default
        if let appSupport = fm.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("MoniVol") {
            try? fm.removeItem(at: appSupport)
        }

        // Clean up log directory
        if let logsDir = fm.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent("Logs/MoniVol") {
            try? fm.removeItem(at: logsDir)
        }

        // Clean up UserDefaults (onboarding state)
        let defaults = UserDefaults.standard
        for key in ["hasCompletedOnboarding", "onboardingVersion",
                     "driverInstallDate", "lastDriverVersionCheck"] {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()

        // Give coreaudiod time to restart, then quit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }
}

struct QuitButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            NSApp.terminate(nil)
        }) {
            Text("Quit MoniVol")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(isHovered ? .white : .primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.accentColor : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}
