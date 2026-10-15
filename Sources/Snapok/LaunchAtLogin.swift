import AppKit
import ServiceManagement

/// Opens Snapok when the user logs in (System Settings → General → Login Items), through `SMAppService`.
/// On by default for new users (macOS announces the new login item; onboarding and Settings turn it off); people
/// updating keep what they had. A login launch stays in the menu bar without opening the main window.
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Registered, but macOS is waiting for the user to allow it in Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Turns it on or off; returns why it failed, if it did.
    static func set(_ enabled: Bool) -> Error? {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            log(enabled ? "login item registration failed" : "login item removal failed", error: error)
            return error
        }
    }

    static func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// First launch of a new user: start at login by default, once. Later changes are the user's.
    static func enableForNewUser() {
        let key = "loginItem.defaultApplied"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard SMAppService.mainApp.status == .notRegistered else { return }
        _ = set(true)
        log("login item enabled by default")
    }

    /// Whether this launch came from the login items; read while launching, when the open event is current.
    static func isLaunchingAtLogin() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }
}
