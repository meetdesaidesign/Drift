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

        // One Drift at a time. Two instances mean two menu-bar items, two return watches,
        // and one of them ending the session the other started — which reads as Drift
        // losing your status at random. `open` reuses a running app, but launching the
        // binary directly does not, and that is easy to do from a build directory.
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "co.drift.app")
            .filter { $0.processIdentifier != mine }
        if !others.isEmpty, ProcessInfo.processInfo.environment["DRIFT_PROBE"] == nil {
            log.log("another Drift is already running; leaving it to it")
            others.first?.activate()
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        AppMenu.install()

        let controller = DriftController()
        self.controller = controller
        self.menuBar = MenuBarController(controller: controller)
        log.log("launch finished")

        switch ProcessInfo.processInfo.environment["DRIFT_PROBE"] {
        case "start":
            MenuBarProbe.runStartCycles(controller: controller)
        case "heckle":
            MenuBarProbe.runHeckled(controller: controller)
        case .some:
            MenuBarProbe.run(menuBar: self.menuBar)
        case nil:
            break
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

            let saver = ScreenSaverInstallation.current()
            print("PROBE  saver installed \(saver.isInstalled)")
            print("PROBE  saver selected  \(saver.isSelected)")
            print("PROBE  engine running  \(ScreenSaverLauncher.isRunning)")

            // The click path, exactly as the button would trigger it.
            menuBar.togglePopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                print("PROBE  popover opens  \(menuBar.popover.isShown)")
                exit(0)
            }
        }
    }
}

extension MenuBarProbe {

    /// Runs the real Start Drift path a few times over and reports what happened each
    /// time, because "it works sometimes" cannot be answered by trying it once.
    ///
    /// Each cycle takes the screen for well under a second and hands it straight back,
    /// which is inside any sane password grace period.
    @MainActor
    static func runStartCycles(controller: DriftController, cycles: Int = 3) {
        func published() -> String {
            SharedStatusFile().readIfAvailable()?.display.text ?? "<no file>"
        }

        Task { @MainActor in
            for cycle in 1...cycles {
                controller.startDrift(status: .preset("lunch"), duration: .minutes(30))

                // Long enough to cover the settle delay, one hold window and a retry.
                var cameUp = false
                for _ in 0..<160 {
                    if ScreenSaverLauncher.isRunning { cameUp = true; break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                // Then let it prove it stays up, which is the part that was failing.
                try? await Task.sleep(for: .seconds(4))
                let stillUp = ScreenSaverLauncher.isRunning
                let onScreen = published()
                let active = controller.store.isActive
                ScreenSaverLauncher.stop()
                controller.endDrift(reason: "probe")
                try? await Task.sleep(for: .milliseconds(600))
                let afterEnd = published()

                let verdict = (cameUp && stillUp && active && onScreen == "Out for lunch" && afterEnd == "Away from desk")
                    ? "PASS" : "FAIL"
                print("PROBE  cycle \(cycle): \(verdict)  came up=\(cameUp)  still up after 4s=\(stillUp)  showed=\"\(onScreen)\"  session=\(active ? "active" : "NOT ACTIVE")  after end=\"\(afterEnd)\"")
                try? await Task.sleep(for: .milliseconds(400))
            }
            exit(0)
        }
    }
}

extension MenuBarProbe {

    /// The failing case, reproduced on purpose: the screensaver is knocked down twice
    /// just after it comes up, the way a hand resting on the trackpad knocks it down.
    /// Drift is expected to put it back and end up holding.
    @MainActor
    static func runHeckled(controller: DriftController) {
        Task { @MainActor in
            controller.startDrift(status: .preset("lunch"), duration: .minutes(30))

            var knocks = 0
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, knocks < 2 {
                try? await Task.sleep(for: .milliseconds(200))
                if ScreenSaverLauncher.isRunning {
                    // Wait a beat so this lands inside the hold window, as a stray touch
                    // would, rather than racing the start itself.
                    try? await Task.sleep(for: .milliseconds(700))
                    ScreenSaverLauncher.stop()
                    knocks += 1
                    print("PROBE  knocked the screensaver down (\(knocks)) — down now: \(!ScreenSaverLauncher.isRunning)")
                }
            }

            // Now leave it alone and see whether Drift got it back up and kept it there.
            try? await Task.sleep(for: .seconds(8))
            let up = ScreenSaverLauncher.isRunning
            let active = controller.store.isActive
            let showing = SharedStatusFile().readIfAvailable()?.display.text ?? "<none>"
            print("PROBE  after being knocked down twice: screensaver=\(up ? "UP" : "down")  session=\(active ? "active" : "ended")  showing=\"\(showing)\"")
            print("PROBE  \(up && active && showing == "Out for lunch" ? "PASS" : "FAIL")")

            ScreenSaverLauncher.stop()
            controller.endDrift(reason: "probe")
            try? await Task.sleep(for: .milliseconds(500))
            exit(0)
        }
    }
}
