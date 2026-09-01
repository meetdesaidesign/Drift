import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by `DriftController.init` so the delegate's lifecycle hooks reach it.
    @MainActor static var controller: DriftController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory, not regular: no Dock icon and no window on launch.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.controller?.applicationWillTerminate()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
