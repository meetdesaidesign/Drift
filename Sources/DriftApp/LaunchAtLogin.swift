import Foundation
import ServiceManagement

/// Launch at login via `SMAppService`, which is the only supported route on modern macOS.
///
/// Caveat worth knowing about on this Mac: Drift is ad-hoc signed, so its code signature
/// changes on every rebuild. launchd keys the registration to that signature, so after a
/// rebuild the login item can go stale and need re-toggling. This is why the UI reads the
/// live status rather than trusting a stored boolean.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // Registering when already enabled throws, so make it idempotent.
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }

    /// Human-readable state, including the cases where macOS needs the user to act.
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "On"
        case .notRegistered:
            return "Off"
        case .requiresApproval:
            return "Needs approval in System Settings › General › Login Items"
        case .notFound:
            return "Unavailable — run Drift from /Applications or ~/Applications"
        @unknown default:
            return "Unknown"
        }
    }
}
