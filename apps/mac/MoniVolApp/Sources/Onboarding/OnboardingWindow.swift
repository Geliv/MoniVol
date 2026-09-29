import AppKit
import SwiftUI

/// Window hosting the single-page onboarding flow.
class OnboardingWindow: NSWindow {
    init(coordinator: OnboardingCoordinator) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
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

    // Allow the onboarding window to become key window (receive keyboard input)
    override var canBecomeKey: Bool {
        return true
    }

    // Allow the onboarding window to become main window
    override var canBecomeMain: Bool {
        return true
    }
}
