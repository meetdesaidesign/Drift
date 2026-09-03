import AppKit
import ScreenSaver
import SwiftUI
import os

private let log = Logger(subsystem: "co.drift.saver", category: "screensaver")

/// Drift's real macOS screensaver.
///
/// It is deliberately dumb: it reaches no network, reads no calendar and writes nothing.
/// All it does is read the resolved status Drift published to
/// `~/Library/Application Support/Drift/status.json` and render it. That matters because
/// this class runs inside `legacyScreenSaver`, which is sandboxed — it has read-only
/// access to the filesystem and no business holding a token.
@objc(DriftScreenSaverView)
public final class DriftScreenSaverView: ScreenSaverView {

    private let sharedFile = SharedStatusFile()
    private var hostingView: NSHostingView<DriftScreenView>!
    private var payload: SharedPayload?
    private var phase: Double = 0
    private var framesSinceReload = 0
    private var framesSinceRefresh = 0
    private var lastModified: Date?

    /// Fast enough for the sign's swing to look like a swing. It only costs this for the
    /// twenty-odd seconds the swing lasts — after that `animateOneFrame` stops rebuilding
    /// the view every frame, and 30fps of nothing is nearly free.
    private static let fps: Double = 30
    /// Re-read status.json about every two seconds, so a status extended with "+10 min"
    /// appears without waiting.
    private static let reloadEveryFrames = 60
    /// Rebuild the SwiftUI view about every 1.5s. The burn-in drift moves a fifth of a
    /// point per second — redrawing it 20 times a second would be 20 times the work for
    /// no visible difference.
    private static let refreshEveryFrames = 45

    private static let backgroundColour = NSColor(
        calibratedRed: 0.0392, green: 0.0392, blue: 0.0392, alpha: 1
    )

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / DriftScreenSaverView.fps
        wantsLayer = true
        layer?.backgroundColor = DriftScreenSaverView.backgroundColour.cgColor

        _ = reload(force: true)

        hostingView = NSHostingView(rootView: makeRootView())
        hostingView.frame = bounds
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)

        log.log("Drift saver initialised (preview: \(isPreview, privacy: .public))")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DriftScreenSaverView is created programmatically only")
    }

    // MARK: Rendering

    private func makeRootView() -> DriftScreenView {
        let now = Date()
        let display = payload?.displayNow(now)
            ?? DisplayStatus(text: DriftSettings.idleText, updatedAt: now)
        return DriftScreenView(display: display, phase: phase, now: now)
    }

    private func refreshRootView() {
        framesSinceRefresh = 0
        hostingView?.rootView = makeRootView()
    }

    /// Reads the published status. Only rebuilds the SwiftUI view when the file actually
    /// changed, so the common case costs one stat() per couple of seconds.
    private func reload(force: Bool) -> Bool {
        let modified = sharedFile.modificationDate()
        if !force, let modified, let lastModified, modified == lastModified { return false }
        lastModified = modified

        if let fresh = sharedFile.readIfAvailable() {
            payload = fresh
            log.log("Read published status (\(fresh.display.text.count, privacy: .public) chars of text)")
        } else {
            // No file yet, or unreadable. Showing "Away from desk" is the correct
            // behaviour here — it is exactly the "nothing to show" case.
            payload = nil
            log.log("No readable status file at \(self.sharedFile.url.path, privacy: .public); showing fallback")
        }
        return true
    }

    // MARK: ScreenSaverView

    public override func startAnimation() {
        super.startAnimation()
        phase = 0
        framesSinceReload = 0
        _ = reload(force: true)
        refreshRootView()
        log.log("startAnimation")
    }

    public override func stopAnimation() {
        super.stopAnimation()
        log.log("stopAnimation")
    }

    public override func animateOneFrame() {
        phase += animationTimeInterval
        framesSinceReload += 1
        framesSinceRefresh += 1

        if framesSinceReload >= DriftScreenSaverView.reloadEveryFrames {
            framesSinceReload = 0
            if reload(force: false) {
                refreshRootView()
                return
            }
        }

        // Every frame while the sign is still swinging; once it has settled, every
        // second and a half — the return line has to keep up with the clock, since
        // "Back around 1:35 PM" becomes "Expected back shortly" on its own, but the
        // burn-in wander moves a fifth of a point per second and does not.
        if DriftScreenView.isSwinging(at: phase)
            || framesSinceRefresh >= DriftScreenSaverView.refreshEveryFrames {
            refreshRootView()
        }
    }

    public override func draw(_ rect: NSRect) {
        // The SwiftUI hosting view draws everything; this only paints the backing colour
        // for the instant before it appears.
        DriftScreenSaverView.backgroundColour.setFill()
        rect.fill()
    }

    public override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        hostingView?.frame = bounds
    }

    /// No configuration sheet: everything is configured in Drift's menu-bar app.
    public override var hasConfigureSheet: Bool { false }
    public override var configureSheet: NSWindow? { nil }
}
