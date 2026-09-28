import Foundation
import Carbon

/// 通过 System Events 管理指向 MoniVol.app 的系统登录项。
enum LoginItemManager {
    private static let scriptSource = """
    on loginitemstate(appPath, actionName)
        tell application "System Events"
            set matchingItems to (every login item whose path is appPath)
            if actionName is "enable" then
                if (count of matchingItems) is 0 then
                    make new login item at end with properties {path:appPath, hidden:false}
                end if
            else if actionName is "disable" then
                repeat with loginEntry in matchingItems
                    delete loginEntry
                end repeat
            end if
            return ((count of (every login item whose path is appPath)) > 0)
        end tell
    end loginitemstate
    """

    static func isEnabled() throws -> Bool {
        try runScript(action: "status")
    }

    static func setEnabled(_ enabled: Bool) throws -> Bool {
        let result = try runScript(action: enabled ? "enable" : "disable")
        guard result == enabled else {
            throw LoginItemError.scriptFailed("Could not update MoniVol's login item.")
        }
        return result
    }

    private static func runScript(action: String) throws -> Bool {
        let appURL = Bundle.main.bundleURL.standardizedFileURL
        guard appURL.pathExtension == "app" else {
            throw LoginItemError.notAppBundle
        }
        guard let script = NSAppleScript(source: scriptSource) else {
            throw LoginItemError.scriptFailed("Could not create the login item script.")
        }

        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kASAppleScriptSuite),
            eventID: AEEventID(kASSubroutineEvent),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: "loginitemstate"),
                       forKeyword: AEKeyword(keyASSubroutineName))
        let arguments = NSAppleEventDescriptor.list()
        arguments.insert(NSAppleEventDescriptor(string: appURL.path), at: 1)
        arguments.insert(NSAppleEventDescriptor(string: action), at: 2)
        event.setParam(arguments, forKeyword: AEKeyword(keyDirectObject))

        var scriptError: NSDictionary?
        let result: NSAppleEventDescriptor? = script.executeAppleEvent(event, error: &scriptError)
        guard let result else {
            let message = scriptError?[NSAppleScript.errorMessage] as? String
                ?? "Could not access macOS login items."
            throw LoginItemError.scriptFailed(message)
        }
        return result.booleanValue
    }
}

private enum LoginItemError: LocalizedError {
    case notAppBundle
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAppBundle:
            return "MoniVol must be launched from its .app bundle to enable login launch."
        case .scriptFailed(let message):
            return message
        }
    }
}
