import AppKit
import ScreenSaver
import SwiftUI
import os

private let log = Logger(subsystem: "co.drift.saver", category: "screensaver")

/// Drift's real macOS screensaver.
///
/// It is deliberately dumb: it reaches no network, reads no calendar and writes nothing.
/// All it does
/// is read the resolved status Drift published to
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
    private var lastModified: Date?

    /// 30fps is plenty for a slow gradient, and keeps the sandboxed process cheap.
    private static let fps: Double = 30
    /// Re-read status.json about every 2s so a status edited mid-session appears.
    private static let reloadEveryFrames = 60

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        animationTimeInterval = 1.0 / DriftScreenSaverView.fps
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.059, blue: 0.070, alpha: 1).cgColor

        reload(force: true)

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
            ?? DisplayStatus(text: DriftSettings.defaultFallbackText, updatedAt: now)
        return DriftScreenView(display: display, phase: phase)
    }

    private func refreshRootView() {
        hostingView?.rootView = makeRootView()
    }

    /// Reads the published status. Only rebuilds the SwiftUI view when the file actually
    /// changed, so the common case costs one stat() per couple of seconds.
    private func reload(force: Bool) {
        let modified = sharedFile.modificationDate()
        if !force, let modified, let lastModified, modified == lastModified { return }
        lastModified = modified

        if let fresh = sharedFile.readIfAvailable() {
            payload = fresh
            log.log("Read published status (\(fresh.display.text.count, privacy: .public) chars of text)")
        } else {
            // No file yet, or unreadable. Showing the fallback is the correct behaviour
            // here — it is exactly the "nothing valid to show" case.
            payload = nil
            log.log("No readable status file at \(self.sharedFile.url.path, privacy: .public); showing fallback")
        }
    }

    // MARK: ScreenSaverView

    public override func startAnimation() {
        super.startAnimation()
        phase = 0
        framesSinceReload = 0
        reload(force: true)
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
        if framesSinceReload >= DriftScreenSaverView.reloadEveryFrames {
            framesSinceReload = 0
            let before = payload?.display
            reload(force: false)
            // An expiry crossing changes what should be on screen without the file
            // changing at all, so the view is refreshed either way below.
            _ = before
        }

        refreshRootView()
    }

    public override func draw(_ rect: NSRect) {
        // The SwiftUI hosting view draws everything; this only paints the backing colour
        // for the instant before it appears.
        NSColor(calibratedRed: 0.055, green: 0.059, blue: 0.070, alpha: 1).setFill()
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
