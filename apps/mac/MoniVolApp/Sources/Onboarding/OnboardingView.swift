import SwiftUI
import AppKit

// MARK: - Onboarding Step

/// The two steps in the simplified onboarding flow
enum OnboardingStep {
    case welcome
    case driverInstall
}

// MARK: - OnboardingView

/// Simplified two-step onboarding: Welcome → Driver Installation
struct OnboardingView: View {
    @ObservedObject var coordinator: OnboardingCoordinator
    @State private var currentStep: OnboardingStep = .welcome

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()

            switch currentStep {
            case .welcome:
                WelcomeStepView(onNext: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep = .driverInstall
                    }
                })
            case .driverInstall:
                DriverInstallStepView(
                    onBack: {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            currentStep = .welcome
                        }
                    },
                    onComplete: {
                        coordinator.complete()
                    }
                )
            }
        }
        .frame(minWidth: 520, minHeight: 400)
    }
}

// MARK: - Step 1: Welcome

/// Welcome page introducing MoniVol and its core functionality
private struct WelcomeStepView: View {
    let onNext: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // App icon / brand
            AppIconView(size: 64)

            VStack(spacing: 12) {
                Text("Welcome to MoniVol")
                    .font(.system(size: 28, weight: .bold))

                Text("MoniVol lets you control HDMI monitor volume with your keyboard volume keys")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }

            Spacer()

            Button(action: onNext) {
                Text("Next")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 120)
            }
            .keyboardShortcut(.return)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 40)
    }
}

// MARK: - Step 2: Driver Installation

/// Driver installation page with progress and completion state
private struct DriverInstallStepView: View {
    let onBack: () -> Void
    let onComplete: () -> Void

    @StateObject private var installer = DriverInstaller()

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            if installer.state.isComplete {
                completionContent
            } else {
                installContent
            }

            Spacer()

            // Bottom buttons
            HStack {
                if !installer.state.isComplete {
                    Button("Back") {
                        onBack()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }

                Spacer()

                if installer.state.isComplete {
                    Button(action: onComplete) {
                        Text("Open MoniVol")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 160)
                    }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                } else if installer.state == .notStarted {
                    Button(action: installDriver) {
                        Text("Install Driver")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 120)
                    }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                } else if installer.state.isFailed {
                    Button(action: installDriver) {
                        Text("Retry")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 120)
                    }
                    .keyboardShortcut(.return)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.bottom, 40)
        }
        .padding(.horizontal, 40)
        .onAppear {
            // If driver is already installed, skip to completion
            if installer.isDriverInstalled() {
                installer.state = .complete
                installer.progress = 1.0
            }
        }
    }

    // MARK: - Install Content

    @ViewBuilder
    private var installContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 40))
                .foregroundColor(.accentColor)

            Text("Install Audio Driver")
                .font(.system(size: 22, weight: .semibold))

            Text("An audio driver is required to enable volume control. This requires an administrator password.")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            if installer.state != .notStarted {
                VStack(spacing: 8) {
                    ProgressView(value: installer.progress)
                        .frame(width: 300)

                    Text(installer.state.description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
        }
    }

    // MARK: - Completion Content

    @ViewBuilder
    private var completionContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Installation Complete")
                .font(.system(size: 22, weight: .semibold))

            Text("Select the MoniVol device in System Settings → Sound to get started")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            // Visual hint for Control Center → Sound
            HStack(spacing: 6) {
                Image(systemName: "switch.2")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("Control Center")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary.opacity(0.6))
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("Sound")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Actions

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
