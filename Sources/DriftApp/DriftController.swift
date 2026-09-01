import AppKit
import Combine
import EventKit
import SwiftUI

/// Wires the store to the things only the app can do: showing Drift full screen, watching
/// for idle, opening Settings, and reading the Calendar on launch.
@MainActor
final class DriftController: ObservableObject {

    let store: StatusStore
    let calendar: CalendarClient
    private let presenter = FullScreenPresenter()
    private let idleMonitor = IdleMonitor()
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var calendarObserver: NSObjectProtocol?

    @Published private(set) var isShowingDrift = false

    init(existingStore: StatusStore? = nil, calendar: CalendarClient = CalendarClient()) {
        self.calendar = calendar
        // Named `existingStore` rather than `store` so it cannot shadow `self.store` in
        // the rest of this initialiser.
        self.store = existingStore ?? StatusStore(fetchEvents: { [calendar] in
            try await calendar.fetchEvents()
        })
        let store = self.store

        presenter.onDismiss = { [weak self] in
            self?.isShowingDrift = false
        }

        // Keep a visible Drift screen in step with the status behind it, so an expiring
        // status flips to "Away from desk" even while it is on screen.
        store.$currentDisplay
            .sink { [weak self] display in
                guard let self, self.presenter.isShowing else { return }
                self.presenter.update(display: display)
            }
            .store(in: &cancellables)

        // Idle activation is opt-in, so react whenever the setting changes.
        store.$settings
            .map { ($0.idleActivationEnabled, $0.idleActivationDelay) }
            .removeDuplicates(by: { $0 == $1 })
            .sink { [weak self] enabled, delay in
                self?.configureIdleMonitor(enabled: enabled, delay: delay)
            }
            .store(in: &cancellables)

        // Re-read as soon as the calendar database changes, rather than waiting up to two
        // minutes for the next tick — a meeting that has just been moved or cancelled
        // should not keep showing.
        calendarObserver = NotificationCenter.default.addObserver(
            forName: CalendarClient.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.store.source == .calendar else { return }
                Task { await self.store.syncCalendar() }
            }
        }

        AppDelegate.controller = self
        start()
    }

    /// Called once, at launch. Publishes the current status so the screensaver has
    /// something to read even before anything is edited, starts the expiry/sync tickers,
    /// and does the launch-time Calendar read.
    private func start() {
        store.publish(force: true)
        store.startTickers()
        Task {
            // Only prompt for Calendar access if the Calendar source is actually in use.
            // Someone using Drift with custom statuses only should never see the prompt.
            if store.source == .calendar, calendar.authorizationStatus == .notDetermined {
                await calendar.requestAccess()
            }
            await store.syncCalendar()
        }
    }

    /// Asks for Calendar access, then syncs. Called from Settings and the popover.
    func requestCalendarAccess() {
        Task {
            await calendar.requestAccess()
            await store.syncCalendar()
        }
    }

    /// Prompts only if macOS has never asked; otherwise just re-reads.
    func ensureCalendarAccess() {
        Task {
            if calendar.authorizationStatus == .notDetermined {
                await calendar.requestAccess()
            }
            await store.syncCalendar()
        }
    }

    /// Opens the Calendars pane of Privacy & Security, for when access was denied and only
    /// the user can undo that.
    func openCalendarPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    func applicationWillTerminate() {
        store.stopTickers()
        idleMonitor.stop()
        presenter.hide()
        if let calendarObserver {
            NotificationCenter.default.removeObserver(calendarObserver)
            self.calendarObserver = nil
        }
    }

    // MARK: Showing Drift

    /// Re-reads the Calendar first, so what appears on screen is as current as it can be —
    /// sync before Drift begins displaying.
    func showDrift() {
        Task {
            await store.syncCalendar()
            store.publish()
            presenter.show(display: store.currentDisplay)
            isShowingDrift = true
        }
    }

    /// Same screen, but without waiting on the network — this is a look, not a departure.
    func previewDrift() {
        store.publish()
        presenter.show(display: store.currentDisplay)
        isShowingDrift = true
    }

    func hideDrift() {
        presenter.hide()
        isShowingDrift = false
    }

    // MARK: Idle

    private func configureIdleMonitor(enabled: Bool, delay: TimeInterval) {
        guard enabled else {
            idleMonitor.stop()
            return
        }
        idleMonitor.onIdle = { [weak self] in
            guard let self, !self.presenter.isShowing else { return }
            self.store.publish()
            self.presenter.show(display: self.store.currentDisplay)
            self.isShowingDrift = true
        }
        // The presenter already closes on any input; this is the backstop for the case
        // where activity happened somewhere the local event monitor could not see it.
        idleMonitor.onActive = { [weak self] in
            self?.hideDrift()
        }
        idleMonitor.start(threshold: delay)
    }

    // MARK: Settings

    func openSettings() {
        if let settingsWindow {
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(controller: self).environmentObject(store))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Drift Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 480, height: 620))
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func quit() {
        applicationWillTerminate()
        NSApp.terminate(nil)
    }
}
