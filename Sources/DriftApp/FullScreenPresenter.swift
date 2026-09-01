import AppKit
import SwiftUI

/// Borderless window that can take key events, which a borderless NSWindow cannot by
/// default — needed so a keypress dismisses Drift.
private final class DriftOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Shows Drift full screen across every display.
///
/// This backs the "Show Drift" and "Preview" buttons, and the optional show-on-idle
/// behaviour. It is a plain window, deliberately:
///
///  - it never draws a password field, an unlock prompt or any Apple branding, so it
///    cannot be mistaken for the lock screen;
///  - it takes no power assertions and changes no energy or screensaver settings, so it
///    cannot delay or prevent the Mac from locking or sleeping normally;
///  - it dismisses itself when the screen locks or the Mac sleeps, so it is never
///    sitting on top of a real lock.
@MainActor
final class FullScreenPresenter {

    private var windows: [NSWindow] = []
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var activityPoller: Task<Void, Never>?
    private var openedAt: Date?
    /// Ignores the input that opened Drift in the first place — without this, the click on
    /// "Show Drift" or the key that triggered it dismisses it again immediately.
    ///
    /// This MUST stay comfortably longer than `activityIdleThreshold`. The activity poller
    /// dismisses when the system reports input more recently than that threshold, and the
    /// click that opened Drift is itself such input — so a grace period shorter than the
    /// threshold makes Drift close about a second after it opens, every time.
    private static let inputGracePeriod: TimeInterval = 2.5
    /// How recent system input has to be for the poller to treat it as "you're back".
    private static let activityIdleThreshold: TimeInterval = 1.0

    private(set) var isShowing = false

    var onDismiss: (() -> Void)?

    func show(display: DisplayStatus) {
        if isShowing {
            update(display: display)
            return
        }
        isShowing = true
        openedAt = Date()

        let start = Date()
        for screen in NSScreen.screens {
            let window = DriftOverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.setFrame(screen.frame, display: true)
            // .screenSaver is the level macOS provides for exactly this kind of overlay.
            // It sits above ordinary windows; it does not and cannot sit above the real
            // lock screen, which is drawn by loginwindow in its own session.
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = true
            window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.059, blue: 0.070, alpha: 1)
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = false
            window.contentView = NSHostingView(
                rootView: DriftScreenTimelineView(display: display, start: start)
            )
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)

        installDismissMonitors()
        startActivityPoller()
    }

    func update(display: DisplayStatus) {
        guard isShowing else { return }
        let start = openedAt ?? Date()
        for window in windows {
            window.contentView = NSHostingView(
                rootView: DriftScreenTimelineView(display: display, start: start)
            )
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        openedAt = nil

        activityPoller?.cancel()
        activityPoller = nil

        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()

        NSApp.setActivationPolicy(.accessory)
        onDismiss?()
    }

    func toggle(display: DisplayStatus) {
        isShowing ? hide() : show(display: display)
    }

    // MARK: Dismissal

    /// A safety net that does not depend on the event monitor.
    ///
    /// Drift's window sits at `.screenSaver` level, so a failure to dismiss would leave a
    /// full-screen window with no obvious way out. This polls the system idle timer —
    /// which is a completely separate mechanism from the local event monitor, and needs no
    /// permissions — and closes Drift the moment the Mac reports any recent input.
    private func startActivityPoller() {
        activityPoller?.cancel()
        activityPoller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard let self, self.isShowing else { return }
                if let openedAt = self.openedAt,
                   Date().timeIntervalSince(openedAt) < FullScreenPresenter.inputGracePeriod {
                    continue
                }
                if IdleMonitor.systemIdleSeconds() < FullScreenPresenter.activityIdleThreshold {
                    self.hide()
                    return
                }
            }
        }
    }

    private func installDismissMonitors() {
        // Any input at all closes Drift — key, click, scroll or a mouse move.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
                       .otherMouseDown, .scrollWheel, .mouseMoved]
        ) { [weak self] event in
            guard let self, self.isShowing else { return event }
            if let openedAt = self.openedAt,
               Date().timeIntervalSince(openedAt) < FullScreenPresenter.inputGracePeriod {
                return nil
            }
            self.hide()
            return nil
        }

        // Get out of the way of the real thing: if the Mac locks or sleeps, Drift closes.
        let lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        observers.append(lockObserver)

        let sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        observers.append(sleepObserver)

        let screensaverObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screensaver.didstart"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        observers.append(screensaverObserver)

        // A display being plugged in or unplugged while Drift is up would leave a screen
        // uncovered, so rebuild the window set.
        let screensObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isShowing, self.windows.count != NSScreen.screens.count else { return }
                let display = (self.windows.first?.contentView as? NSHostingView<DriftScreenTimelineView>)?.rootView.display
                self.hide()
                if let display { self.show(display: display) }
            }
        }
        observers.append(screensObserver)
    }
}
