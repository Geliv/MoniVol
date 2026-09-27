import AppKit
import SwiftUI

/// Custom borderless NSWindow for onboarding flow with vintage paper background
class OnboardingWindow: NSWindow {
    init(coordinator: OnboardingCoordinator) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        self.isReleasedWhenClosed = false
        self.title = "MoniVol"
        self.hasShadow = true

        // Center on screen
        self.center()

        // Set up SwiftUI content
        let contentView = OnboardingView(coordinator: coordinator)
        self.contentView = NSHostingView(rootView: contentView)

        // Make the window draggable by clicking anywhere on the background
        self.isMovableByWindowBackground = true

        // Set level to ensure visibility
        self.level = .floating
    }

    // Allow the borderless window to become key window (receive keyboard input)
    override var canBecomeKey: Bool {
        return true
    }

    // Allow the borderless window to become main window
    override var canBecomeMain: Bool {
        return true
    }
}
