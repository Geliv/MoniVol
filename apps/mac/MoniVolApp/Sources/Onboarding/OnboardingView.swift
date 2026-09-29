import AppKit
import SwiftUI

/// Single-page setup flow for installing the audio driver and opening MoniVol.
struct OnboardingView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    @StateObject private var installer = DriverInstaller()

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            RadialGradient(
                colors: [Color.accentColor.opacity(0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.08),
                startRadius: 12,
                endRadius: 280
            )
            .ignoresSafeArea()

            setupContent
        }
        .frame(width: 680, height: 520)
        .onAppear {
            if installer.isDriverInstalled() {
                installer.state = .complete
                installer.progress = 1.0
            }
        }
    }

    private var setupContent: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                AppIconView(size: 88)

                Text("Set up MoniVol")
                    .font(.system(size: 32, weight: .bold))

                Text("MoniVol lets you control your external monitor volume\nwith your keyboard volume keys.")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
            }

            VStack(spacing: 0) {
                setupStep(
                    number: 1,
                    icon: "gearshape.fill",
                    title: installer.state.isComplete ? "Audio Driver Installed" : "Install Audio Driver",
                    detail: driverStepDetail,
                    isActive: !installer.state.isComplete,
                    isComplete: installer.state.isComplete
                )

                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                    .frame(height: 1)
                    .padding(.leading, 94)

                setupStep(
                    number: 2,
                    icon: "speaker.wave.2.fill",
                    title: "Select MoniVol in Sound Settings",
                    detail: "Open System Settings → Sound and select the\nMoniVol device to get started.",
                    isActive: installer.state.isComplete,
                    isComplete: false
                )
            }
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
            }

            Spacer(minLength: 0)

            actions
        }
        .padding(.top, 24)
        .padding(.horizontal, 48)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setupStep(
        number: Int,
        icon: String,
        title: String,
        detail: String,
        isActive: Bool,
        isComplete: Bool
    ) -> some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(stepIndicatorColor(isActive: isActive, isComplete: isComplete))

                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(isActive ? .white : .secondary)
                }
            }
            .frame(width: 38, height: 38)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.08))

                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(isComplete ? .green : (isActive ? .accentColor : .secondary))
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.primary)

                Text(detail)
                    .font(.system(size: 13.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isInstalling && number == 1 {
                    ProgressView(value: installer.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 260)
                        .padding(.top, 3)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(isActive ? Color.accentColor.opacity(0.055) : .clear)
    }

    private var actions: some View {
        HStack {
            if !installer.state.isComplete {
                Button("Skip for now") {
                    coordinator.complete()
                }
                .controlSize(.large)
            }

            Spacer()

            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if installer.state.isComplete {
            Button("Open MoniVol") {
                coordinator.complete()
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minWidth: 150)
        } else if installer.state.isFailed {
            Button("Retry", action: installDriver)
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minWidth: 150)
        } else {
            Button(isInstalling ? "Installing…" : "Install Driver", action: installDriver)
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minWidth: 150)
                .disabled(isInstalling)
        }
    }

    private var isInstalling: Bool {
        installer.state != .notStarted
            && !installer.state.isComplete
            && !installer.state.isFailed
    }

    private var driverStepDetail: String {
        switch installer.state {
        case .notStarted:
            return "An audio driver is required to enable volume control.\nThis requires an administrator password."
        case .complete:
            return "The audio driver is installed and ready."
        case .failed(let message):
            return "Installation failed: \(message)"
        default:
            return installer.state.description
        }
    }

    private func stepIndicatorColor(isActive: Bool, isComplete: Bool) -> Color {
        if isComplete {
            return .green
        }
        if isActive {
            return .accentColor
        }
        return Color.secondary.opacity(0.14)
    }

    private func installDriver() {
        Task {
            do {
                try await installer.installDriver()
            } catch {
                await MainActor.run {
                    installer.state = .failed(error.localizedDescription)
                }
            }
        }
    }
}
