import AppKit
import CoreGraphics
import SwiftUI

/// Wires the store to the things only the app can do: starting the screensaver, noticing
/// when you come back, opening Settings, and quitting.
@MainActor
final class DriftController: ObservableObject {

    let store: StatusStore
    private var settingsWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var returnWatch: Task<Void, Never>?

    /// Set when Start Drift could not hand over to the screensaver. Shown in the popover
    /// rather than as an alert — and the session is ended, because a status nothing is
    /// displaying is not a status.
    @Published private(set) var startError: String?

    init(existingStore: StatusStore? = nil) {
        // Named `existingStore` rather than `store` so it cannot shadow `self.store`.
        self.store = existingStore ?? StatusStore()

        // Publish at launch so the screensaver has something to read even if Drift is
        // never opened — an idle Mac should say "Away from desk", not show whatever was
        // left in the file.
        store.publish(force: true)
        installReturnObservers()
    }

    // MARK: Starting and ending

    /// Publishes the status, then hands the screen to the system screensaver.
    ///
    /// This is the only path in Drift that leaves the Mac locked, and the order matters.
    /// `store.start` writes `status.json` synchronously, so by the time the saver's view
    /// is created the file already holds the status you just picked — publish afterwards
    /// and Drift comes up showing the previous one until its next poll catches up.
    ///
    /// Nothing here touches a security setting. Whether a password is required after the
    /// screensaver begins, and after how long, belongs to macOS.
    func startDrift(status: StatusChoice, duration: DurationChoice) {
        startError = nil
        guard store.start(status: status, duration: duration) else { return }
        beginWatchingForReturn()

        Task {
            do {
                try await ScreenSaverLauncher.start()
            } catch {
                startError = error.localizedDescription
                endDrift()
            }
        }
    }

    /// "+10 min", for when lunch runs long.
    func extendDrift() {
        store.extend(byMinutes: 10)
    }

    func endDrift() {
        returnWatch?.cancel()
        returnWatch = nil
        store.end()
    }

    // MARK: Noticing that you came back

    /// The screensaver stopping *is* the user returning: macOS ends it on the first key
    /// or click, and on unlock. Both notifications are watched, and both are cheap.
    private func installReturnObservers() {
        for name in ["com.apple.screensaver.didstop", "com.apple.screenIsUnlocked"] {
            let observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.store.isActive else { return }
                    self.endDrift()
                }
            }
            observers.append(observer)
        }
    }

    /// A backstop for the notifications above, which are Apple's and undocumented.
    ///
    /// It watches for input rather than for the screensaver going away. Asking macOS
    /// whether the screensaver is still up lags: `SACScreenSaverIsRunning` was measured
    /// here still answering yes several seconds after it had been told to stop, and the
    /// host process is no signal at all. Input is unambiguous — if the Mac has seen a key
    /// or the trackpad in the last couple of seconds, you are sitting in front of it, and
    /// the screensaver you had to dismiss to do that is gone.
    ///
    /// `startupGrace` exists because starting Drift *is* input: without it the session
    /// would end a second after it began.
    private func beginWatchingForReturn() {
        returnWatch?.cancel()
        returnWatch = Task { [weak self] in
            let startedAt = Date()
            let startupGrace: TimeInterval = 6
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                guard let self, self.store.isActive else { return }
                guard Date().timeIntervalSince(startedAt) > startupGrace else { continue }
                if DriftController.secondsSinceInput() < 2 {
                    self.endDrift()
                    return
                }
            }
        }
    }

    /// How long since the Mac last saw a key, a click or the trackpad.
    ///
    /// `CGEventSource` needs no Accessibility permission and no event tap — Drift never
    /// observes *what* you type, only how long ago you last did anything.
    private static func secondsSinceInput() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return .infinity }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }

    // MARK: Lifecycle

    func applicationWillTerminate() {
        returnWatch?.cancel()
        returnWatch = nil
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        // Leave the published file idle: with Drift gone, nothing can end a session, so
        // a live one on disk would tell every later screensaver you were still at lunch.
        store.end()
    }

    // MARK: Settings and About

    /// Opens System Settings › Screen Saver, where `Drift.saver` has to be chosen by hand
    /// — that selection lives in a binary plist macOS owns and cannot be scripted.
    func openScreenSaverSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.ScreenSaver-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    func openSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(controller: self).environmentObject(store))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Drift Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
