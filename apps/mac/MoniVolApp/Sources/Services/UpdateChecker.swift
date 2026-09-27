import AppKit
import Foundation

/// Checks GitHub Releases only when the user requests it from the menu.
@MainActor
enum UpdateChecker {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/Geliv/MoniVol/releases/latest")!
    private static let releasesPageURL = URL(string: "https://github.com/Geliv/MoniVol/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
    }

    static func checkForUpdates() async {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MoniVol", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                throw UpdateError.unavailable
            }

            let release = try JSONDecoder().decode(Release.self, from: data)
            let version = release.tag_name.hasPrefix("v")
                ? String(release.tag_name.dropFirst()) : release.tag_name
            guard !version.isEmpty,
                  version.split(separator: ".").allSatisfy({ Int($0) != nil }) else {
                throw UpdateError.unavailable
            }

            let alert = NSAlert()
            if let installedVersion = VersionManager.appVersion(),
               VersionManager.isVersionOlder(installedVersion, than: version) {
                alert.messageText = "MoniVol \(version) Is Available"
                alert.informativeText = "You have version \(installedVersion). Open the release page to download the latest version."
                alert.addButton(withTitle: "View Release")
                alert.addButton(withTitle: "Later")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(releasesPageURL)
                }
            } else {
                alert.messageText = "MoniVol Is Up to Date"
                alert.informativeText = "The latest release is version \(version)."
                alert.addButton(withTitle: "OK")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Unable to Check for Updates"
            alert.informativeText = "Could not load the latest MoniVol release from GitHub. Open the releases page in your browser to check manually."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releasesPageURL)
            }
        }
    }

    private enum UpdateError: Error {
        case unavailable
    }
}
