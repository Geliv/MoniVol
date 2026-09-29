import Foundation
import Sparkle

/// Connects MoniVol's existing update buttons to Sparkle's standard updater.
enum UpdateChecker {
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    static func start() {
        _ = controller
    }

    static func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
