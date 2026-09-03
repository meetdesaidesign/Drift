import AppKit
import os

/// Launch and menu-bar logging. Drift has no window to report trouble in, so when the
/// status item does not appear the unified log is the only place to look:
///
///   log show --last 10m --predicate 'subsystem == "co.drift.app"' --style compact
let log = Logger(subsystem: "co.drift.app", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var controller: DriftController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory, not regular: no Dock icon and no window on launch.
        log.log("applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.accessory)
        AppMenu.install()

        let controller = DriftController()
        self.controller = controller
        self.menuBar = MenuBarController(controller: controller)
        log.log("launch finished")

        if ProcessInfo.processInfo.environment["DRIFT_PROBE"] != nil {
            MenuBarProbe.run(menuBar: self.menuBar)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller?.applicationWillTerminate()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// A minimal main menu.
///
/// An accessory app never displays a menu bar of its own, so none of this is ever seen —
/// but `NSApp.mainMenu` is also where key equivalents are resolved, and without it ⌘C,
/// ⌘V, ⌘A and ⌘Z do nothing in the custom-message field.
enum AppMenu {

    @MainActor
    static func install() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About Drift",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Drift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

/// Self-check for the one thing that cannot be verified from outside this process.
///
/// An invisible status item leaves no trace to read on this Mac: `screencapture` needs
/// Screen Recording permission and `log show` needs Full Disk Access. So Drift, run with
/// `DRIFT_PROBE=1`, reports where its own menu-bar item landed and whether its popover
/// opens, on stdout, and then quits. See tools/menubar-probe.sh.
enum MenuBarProbe {

    @MainActor
    static func run(menuBar: MenuBarController?) {
        guard let menuBar else { print("PROBE  no MenuBarController"); exit(1) }
        // A turn of the run loop first: the status item gets its window from the system,
        // not synchronously at creation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let item = menuBar.statusItem
            print("PROBE  isVisible      \(item.isVisible)")
            print("PROBE  length         \(item.length)")
            print("PROBE  has image      \(item.button?.image != nil)")
            print("PROBE  autosaveName   \(item.autosaveName ?? "none")")

            if let button = item.button, let window = button.window {
                let f = window.frame
                print("PROBE  item window    x \(Int(f.minX)) … \(Int(f.maxX)), y \(Int(f.minY)), on screen \(window.isVisible)")
                if let screen = NSScreen.main, let left = screen.auxiliaryTopLeftArea,
                   let right = screen.auxiliaryTopRightArea,
                   f.maxX > left.maxX, f.minX < right.minX {
                    print("PROBE  VERDICT        under the notch — invisible and unclickable")
                } else {
                    print("PROBE  VERDICT        the item has a visible slot")
                }
                print("PROBE  target/action  \(button.target != nil) / \(button.action?.description ?? "none")")
            } else {
                print("PROBE  item window    NONE — nothing is in the menu bar")
            }

            // The click path, exactly as the button would trigger it.
            menuBar.togglePopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                print("PROBE  popover opens  \(menuBar.popover.isShown)")
                exit(0)
            }
        }
    }
}
