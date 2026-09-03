import AppKit

/// AppKit's own entry point rather than SwiftUI's `App`.
///
/// Drift is one status item and one popover, and it needs to close that popover itself —
/// on Start Drift, and on Escape. `MenuBarExtra` hands out no such control, so the status
/// item and the `NSPopover` are owned directly (see `MenuBarController`). Everything
/// inside the popover is still SwiftUI.
@main
struct DriftAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
