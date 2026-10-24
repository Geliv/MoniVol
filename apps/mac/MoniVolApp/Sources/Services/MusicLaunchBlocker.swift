import AppKit
import Combine

/// Listens for future Apple Music launches while the optional blocker is enabled.
/// Settings and observer lifecycle are managed on the main thread.
final class MusicLaunchBlocker: ObservableObject {
    static let shared = MusicLaunchBlocker()
    static let storageKey = "blockAppleMusicLaunch"

    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.storageKey)
            if isEnabled {
                start()
            } else {
                stop()
            }
        }
    }

    private var launchObserver: NSObjectProtocol?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.storageKey)
    }

    func start() {
        guard isEnabled, launchObserver == nil else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard self?.isEnabled == true,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Music" else { return }

            // Launch notifications do not identify whether the launch was manual.
            // Only handle new launches; leave any existing Music session alone.
            app.forceTerminate()
        }
    }

    func stop() {
        guard let launchObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(launchObserver)
        self.launchObserver = nil
    }
}
