import AppKit
import CoreGraphics
import SwiftUI

/// Wires the store to the things only the app can do: starting the screensaver, noticing
/// when you come back, opening Settings, and quitting.
@MainActor
final class DriftController: ObservableObject {

    let store: StatusStore
    private var settingsWindow: NSWindow?
    private var returnWatch: Task<Void, Never>?
    private let stayLit = StayLit()

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
        // Before the screensaver, not after: this Mac turns its display off after five
        // minutes, and a sign on a dark screen is not a sign. See `StayLit`.
        stayLit.hold()
        EventLog.append("start: session begun, starting the screensaver")

        Task {
            do {
                try await ScreenSaverLauncher.startAndHold { EventLog.append("start: \($0)") }
                // Only now: watching for a return before the screensaver has settled is
                // how a session ends two seconds after it began.
                beginWatchingForReturn()
            } catch {
                startError = error.localizedDescription
                EventLog.append("start FAILED: \(error.localizedDescription)")
                endDrift(reason: "start failed")
            }
        }
    }

    /// "+10 min", for when lunch runs long.
    func extendDrift() {
        store.extend(byMinutes: 10)
    }

    func endDrift(reason: String = "asked") {
        returnWatch?.cancel()
        returnWatch = nil
        stayLit.release()
        if store.isActive { EventLog.append("end (\(reason))") }
        store.end()
    }

    // MARK: Noticing that you came back

    /// Nothing here listens for a notification any more, and that is deliberate.
    ///
    /// Both of the obvious ones lie. `com.apple.screensaver.didstop` means the screensaver
    /// stopped, which is exactly what a hand brushing the trackpad does — and
    /// `com.apple.screenIsUnlocked` fires on that same brush, because dismissing the
    /// screensaver inside the password grace period unlocks the screen without asking for
    /// anything. Both were measured firing one second into a session that had barely
    /// begun, ending it and republishing "Away from desk" while the screensaver was on its
    /// way back up.
    ///
    /// Whether you are back is not an event. It is a question about the next few seconds,
    /// which is what the watchdog below answers.

    /// Keeps the sign up, and ends the session only when you are actually back.
    ///
    /// Armed once the screensaver has held, so by the time this runs the screensaver being
    /// gone means something took it down. Two things can do that and they look identical
    /// at the instant it happens — a hand brushing the trackpad, and you sitting back
    /// down. What tells them apart is what happens next: presence continues, a brush does
    /// not.
    ///
    /// So while a session is live: if the screensaver is down and nobody has touched
    /// anything for a few seconds, put it back up — that is a brush, and the sign should
    /// still be showing. If input keeps coming for several checks in a row, you are back,
    /// and the session ends. Somebody who has changed their mind gets the screensaver
    /// restored once and then, by carrying on using the Mac, ends the session anyway.
    private func beginWatchingForReturn() {
        returnWatch?.cancel()
        returnWatch = Task { [weak self] in
            var presenceTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { return }
                guard let self, self.store.isActive else { return }

                if ScreenSaverLauncher.isRunning {
                    presenceTicks = 0
                    continue
                }

                if DriftController.secondsSinceInput() < 2 {
                    presenceTicks += 1
                    // Roughly six seconds of continuous input. Nobody brushes a trackpad
                    // for six seconds.
                    if presenceTicks >= 3 {
                        self.endDrift(reason: "you came back")
                        return
                    }
                } else {
                    presenceTicks = 0
                    EventLog.append("watchdog: the sign was down with nobody here, putting it back")
                    try? await ScreenSaverLauncher.start()
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
        stayLit.release()
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
