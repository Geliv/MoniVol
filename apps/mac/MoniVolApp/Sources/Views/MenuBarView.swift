import SwiftUI
import AppKit

struct MenuBarView: View {
    @StateObject private var volumeController = VolumeController.shared
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.systemDefault.rawValue
    @State private var showOptions = false
    @State private var showLanguages = false
    @State private var opensAtLogin = false
    @State private var isUpdatingLoginItem = false

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .systemDefault
    }

    private var activeDevice: OutputDevice? {
        volumeController.allDevices.first { $0.uid == volumeController.activeDeviceUID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, 10)

            ActiveDeviceCard(
                deviceName: volumeController.activeDeviceName,
                isFixed: activeDevice?.isFixedVolume ?? false,
                canAdjustVolume: volumeController.isFixedVolumeDevice,
                volume: Binding(
                    get: { volumeController.currentVolume },
                    set: { volumeController.setVolume($0) }
                ),
                isMuted: volumeController.isMuted,
                onToggleMute: { volumeController.setMute(!volumeController.isMuted) },
                language: language
            )
            .padding(.bottom, 13)

            HStack {
                Text(language.text("Output Device", "输出设备"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                ReconnectAudioButton(language: language)
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 7)

            DeviceListSection(
                devices: volumeController.allDevices,
                activeUID: volumeController.activeDeviceUID,
                language: language,
                onSelect: { volumeController.switchDevice(to: $0) }
            )
            .padding(.bottom, 12)

            Text(language.text("Language", "语言"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 2)
                .padding(.bottom, 6)

            Button {
                showLanguages.toggle()
                showOptions = false
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "globe")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                    Text(language.name)
                        .font(.system(size: 12))
                    Spacer()
                    Image(systemName: showLanguages ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 34)
                .frame(maxWidth: .infinity)
                .background(languageFieldShape)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showLanguages {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(AppLanguage.allCases, id: \.rawValue) { option in
                            if option != .english {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.08))
                                    .frame(height: 1)
                            }
                            languageOption(option)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 4 * 27 + 4 + 12)
                .padding(4)
                .background(panelShape)
                .padding(.top, 4)
            }
            Color.clear.frame(height: 11)

            Rectangle()
                .fill(Color.primary.opacity(0.09))
                .frame(height: 1)
                .padding(.bottom, 8)

            HStack {
                Text(VersionManager.appVersion().map { "MoniVol v\($0)" } ?? "MoniVol")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label(language.text("Quit App", "退出应用"), systemImage: "power")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 11)
                        .frame(height: 28)
                }
                .buttonStyle(.plain)
                .background(panelShape)
            }
        }
        .padding(12)
        .frame(width: 300)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if showOptions {
                Color.clear
                    .contentShape(Rectangle())
                    .padding(.top, 52)
                    .onTapGesture { showOptions = false }
            }
        }
        .overlay(alignment: .topTrailing) {
            if showOptions {
                optionsMenu
                    .padding(.top, 52)
                    .padding(.trailing, 12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(.primary.opacity(0.75))
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("MoniVol")
                    .font(.system(size: 17, weight: .bold))
                Text(language.text("External display volume", "调节外接显示器音量"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)

            Button {
                showOptions.toggle()
                showLanguages = false
                if showOptions { refreshLoginItemState() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(Color.primary.opacity(showOptions ? 0.12 : 0.06))
                            .overlay {
                                Circle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                            }
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(language.text("More options", "更多选项"))
        }
    }

    private var optionsMenu: some View {
        VStack(spacing: 2) {
            Button(action: toggleOpenAtLogin) {
                OptionsMenuRow(
                    title: language.text("Open at Login", "登录时打开"),
                    symbol: nil,
                    isChecked: opensAtLogin
                )
            }
            .disabled(isUpdatingLoginItem)

            Button {
                showOptions = false
                UpdateChecker.checkForUpdates()
            } label: {
                OptionsMenuRow(
                    title: language.text("Check for Updates", "检查更新"),
                    symbol: "arrow.triangle.2.circlepath"
                )
            }

            UninstallButton(language: language, onSelect: { showOptions = false })

            Button {
                showOptions = false
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            } label: {
                OptionsMenuRow(
                    title: language.text("About MoniVol", "关于 MoniVol"),
                    symbol: "info.circle"
                )
            }
        }
        .buttonStyle(.plain)
        .padding(5)
        .frame(width: 205)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 13, y: 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.13), lineWidth: 1)
                }
        )
    }

    private func refreshLoginItemState() {
        isUpdatingLoginItem = true
        DispatchQueue.global(qos: .userInitiated).async {
            let enabled = try? LoginItemManager.isEnabled()
            DispatchQueue.main.async {
                if let enabled { opensAtLogin = enabled }
                isUpdatingLoginItem = false
            }
        }
    }

    private func toggleOpenAtLogin() {
        isUpdatingLoginItem = true
        let shouldEnable = !opensAtLogin
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LoginItemManager.setEnabled(shouldEnable) }
            DispatchQueue.main.async {
                isUpdatingLoginItem = false
                switch result {
                case .success(let enabled):
                    opensAtLogin = enabled
                case .failure(let error):
                    let alert = NSAlert()
                    alert.messageText = language.text("Could Not Change Login Setting", "无法更改登录设置")
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }

    private func languageOption(_ option: AppLanguage) -> some View {
        Button {
            languageCode = option.rawValue
            showLanguages = false
        } label: {
            HStack {
                Text(option.name)
                    .font(.system(size: 12))
                Spacer()
                if language == option {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.blue)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 27)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var panelShape: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }

    private var languageFieldShape: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
            }
    }
}

private struct OptionsMenuRow: View {
    let title: String
    let symbol: String?
    var isChecked = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .foregroundColor(.secondary)
                } else {
                    Image(systemName: isChecked ? "checkmark.square" : "square")
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 13))
            .frame(width: 18)
            Text(title)
                .font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 31)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

private struct ActiveDeviceCard: View {
    let deviceName: String
    let isFixed: Bool
    let canAdjustVolume: Bool
    @Binding var volume: Float
    let isMuted: Bool
    let onToggleMute: () -> Void
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isFixed ? "display" : "speaker.wave.2")
                    .font(.system(size: 23, weight: .light))
                    .foregroundColor(.primary.opacity(0.7))
                    .frame(width: 34, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(deviceName.isEmpty
                        ? language.text("No Device", "无设备")
                        : deviceName)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(deviceCategory(name: deviceName, isFixed: isFixed, language: language))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
            }

            if canAdjustVolume {
                HStack(spacing: 8) {
                    Button(action: onToggleMute) {
                        Image(systemName: volumeIcon(volume: volume, muted: isMuted))
                            .font(.system(size: 15))
                            .frame(width: 19)
                    }
                    .buttonStyle(.plain)
                    .help(language.text("Mute or unmute", "静音或取消静音"))

                    Slider(value: Binding(
                        get: { Double(volume) },
                        set: { volume = Float($0) }
                    ), in: 0...1)
                    .tint(.blue)

                    Text("\(Int(volume * 100))%")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 35, alignment: .trailing)
                }
            } else {
                Text(language.text(
                    "This device supports native volume control",
                    "此设备使用系统原生音量控制"
                ))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                }
        )
    }

    private func volumeIcon(volume: Float, muted: Bool) -> String {
        if muted || volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.33 { return "speaker.wave.1.fill" }
        if volume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

private struct FixedBadge: View {
    let language: AppLanguage

    var body: some View {
        Text(language.text("Fixed", "已修复"))
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(Color(red: 0.73, green: 0.33, blue: 0.04))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.orange.opacity(0.19))
            )
    }
}

private func deviceCategory(name: String, isFixed: Bool, language: AppLanguage) -> String {
    if isFixed { return language.text("External Display", "外接显示器") }
    if name.localizedCaseInsensitiveContains("MacBook")
        || name.localizedCaseInsensitiveContains("Built-in")
        || name.contains("内建")
        || name.contains("扬声器") {
        return language.text("Built-in Output", "内建输出")
    }
    return language.text("Audio Output", "音频输出")
}

private func deviceSymbol(name: String, isFixed: Bool) -> String {
    if isFixed { return "display" }
    if name.localizedCaseInsensitiveContains("MacBook")
        || name.localizedCaseInsensitiveContains("Built-in")
        || name.contains("内建") {
        return "laptopcomputer"
    }
    return "speaker.wave.2"
}

private struct DeviceListSection: View {
    let devices: [OutputDevice]
    let activeUID: String
    let language: AppLanguage
    let onSelect: (OutputDevice) -> Void
    private let maxVisibleDevices = 5
    private let rowHeight: CGFloat = 44
    private let dividerHeight: CGFloat = 1

    var body: some View {
        Group {
            if devices.count > maxVisibleDevices {
                ScrollView(.vertical) { rows }
                    .frame(height: CGFloat(maxVisibleDevices) * rowHeight
                        + CGFloat(maxVisibleDevices - 1) * dividerHeight)
            } else {
                rows
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
        )
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(devices) { device in
                if device.uid != devices.first?.uid {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 8)
                }
                DeviceRow(
                    device: device,
                    isActive: device.uid == activeUID,
                    language: language,
                    onSelect: { onSelect(device) }
                )
            }
        }
    }
}

private struct DeviceRow: View {
    let device: OutputDevice
    let isActive: Bool
    let language: AppLanguage
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(isActive ? .blue : .secondary)
                    .frame(width: 20)

                Image(systemName: deviceSymbol(name: device.name, isFixed: device.isFixedVolume))
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.primary.opacity(0.7))
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(deviceCategory(
                        name: device.name,
                        isFixed: device.isFixedVolume,
                        language: language
                    ))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                }
                Spacer(minLength: 4)
                if device.isFixedVolume {
                    FixedBadge(language: language)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? Color.blue.opacity(0.09) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ReconnectAudioButton: View {
    let language: AppLanguage
    @State private var isBouncing = false
    @State private var showDone = false

    var body: some View {
        Button(action: reconnect) {
            HStack(spacing: 5) {
                if isBouncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: showDone ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                }
                Text(showDone
                    ? language.text("Reconnected", "已重新连接")
                    : language.text("Reconnect", "重新连接"))
                    .font(.system(size: 11))
            }
            .foregroundColor(showDone ? .green : .secondary)
        }
        .buttonStyle(.plain)
        .disabled(isBouncing)
    }

    private func reconnect() {
        isBouncing = true
        VolumeController.shared.bounceDevice()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            isBouncing = false
            showDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                showDone = false
            }
        }
    }
}

private struct UninstallButton: View {
    let language: AppLanguage
    let onSelect: () -> Void

    var body: some View {
        Button {
            onSelect()
            performUninstall()
        } label: {
            OptionsMenuRow(
                title: language.text("Uninstall Driver", "卸载驱动"),
                symbol: "trash"
            )
        }
    }

    private func performUninstall() {
        let alert = NSAlert()
        alert.messageText = language.text("Uninstall MoniVol Driver", "卸载 MoniVol 驱动")
        alert.informativeText = language.text("This will remove the audio driver, stop background processes, and clear configuration data. The app itself will not be deleted — you can reinstall the driver anytime.", "这会移除音频驱动、停止后台进程并清除配置数据。应用本身不会被删除，之后可重新安装驱动。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: language.text("Uninstall Driver", "卸载驱动"))
        alert.addButton(withTitle: language.text("Cancel", "取消"))

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        // Tell AppDelegate we're uninstalling so the Host watchdog stays idle.
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.isUninstalling = true
        }

        // Step 1: Kill host and remove driver (requires admin).
        // Each command is guarded with "|| true" so a single failure
        // (e.g. coreaudiod restart returning non-zero) does not abort
        // the entire script and cause the app to skip cleanup.
        let script = """
        do shell script "killall MoniVolHost 2>/dev/null || true; \
        rm -rf /Library/Audio/Plug-Ins/HAL/MoniVolDriver.driver || true; \
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
                     "driverInstallDate", "lastDriverVersionCheck",
                     AppLanguage.storageKey, "menuLanguage"] {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()

        // Give coreaudiod time to restart, then quit
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            NSApp.terminate(nil)
        }
    }
}
