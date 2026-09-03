import AppKit

/// Starts the system screensaver on demand, and reports what macOS will do about locking
/// once it has.
///
/// Why the screensaver and not a window of Drift's own: a window lives in your logged-in
/// session, so while it is up the Mac is *not* locked. The screensaver is the other way
/// round — macOS draws it *over* a locked session, so the installed `Back Soon.saver`
/// keeps showing your status while the Mac is genuinely locked behind it. That makes the
/// screensaver the only mechanism that does both at once.
///
/// Nothing here changes a security setting. Whether a password is required after the
/// screensaver begins, and after how long, belongs to macOS; Drift only reads it, so it
/// can tell you the truth about what stepping away will actually do.
@MainActor
enum ScreenSaverLauncher {

    enum Failure: LocalizedError {
        case engineMissing
        case launchFailed(String)
        case didNotStart

        var errorDescription: String? {
            switch self {
            case .engineMissing:
                return "This Mac has no way for Drift to start the screensaver."
            case .launchFailed(let message):
                return "Could not start the screensaver: \(message)"
            case .didNotStart:
                return "macOS did not start the screensaver. Check that a screensaver is chosen in System Settings › Screen Saver."
            }
        }
    }

    static let engineURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")

    /// macOS 26 no longer starts the screensaver when `ScreenSaverEngine.app` is
    /// launched. Measured on this Mac: `open -a ScreenSaverEngine`, running its binary
    /// directly, and `open -b com.apple.ScreenSaver.Engine` all exit without taking the
    /// screen. That is the whole reason Start Drift appeared to do nothing.
    ///
    /// What does work is the call the system's own hot corners and menu items use. It is
    /// private, so every symbol is resolved by name and absence is handled rather than
    /// assumed: if a future macOS drops it, Drift falls back to the old engine launch and,
    /// failing that, says it could not start rather than pretending it did.
    private enum LoginFramework {
        private static let path = "/System/Library/PrivateFrameworks/login.framework/login"
        private typealias Call = @convention(c) () -> Int32

        private static func call(_ name: String) -> Call? {
            guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) else {
                return nil
            }
            return unsafeBitCast(symbol, to: Call.self)
        }

        static func startNow() -> Int32? { call("SACScreenSaverStartNow").map { $0() } }
        static func stopNow() -> Int32? { call("SACScreenSaverStopNow").map { $0() } }
        static func isRunning() -> Bool? { call("SACScreenSaverIsRunning").map { $0() != 0 } }
    }

    /// Whether the screensaver has the screen.
    ///
    /// `legacyScreenSaver` deliberately does not count towards this, and that is the point
    /// of this comment: it is the sandboxed host that draws a third-party `.saver`, and it
    /// also runs when nothing is on screen at all — System Settings keeps one alive to
    /// render the preview thumbnail of the selected screensaver. Counting it made Start
    /// Drift decide the screensaver was already up, so it published the status, launched
    /// nothing, reported no error, and left a session running over an ordinary desktop.
    private static let engineBundleID = "com.apple.ScreenSaver.Engine"

    static var isRunning: Bool {
        LoginFramework.isRunning() ?? engineIsRunning
    }

    private static var engineIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == engineBundleID }
    }

    /// Starts the screensaver, and then goes back and checks that it really did.
    ///
    /// The second look is the point. Both routes below can report success and leave the
    /// screen untouched, and their failure mode is silence rather than an error — so Drift
    /// waits and looks instead of assuming.
    static func start() async throws {
        if isRunning { return }

        if let result = LoginFramework.startNow() {
            try? await Task.sleep(for: .milliseconds(700))
            if result == 0, isRunning { return }
        }

        // The pre-macOS-26 route, kept as a fallback rather than removed: it is the
        // documented one, and it may well come back.
        guard FileManager.default.fileExists(atPath: engineURL.path) else {
            throw Failure.engineMissing
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: engineURL, configuration: configuration)
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }
        try? await Task.sleep(for: .milliseconds(1500))
        guard isRunning else { throw Failure.didNotStart }
    }

    /// Takes the screensaver back down. Only used by the diagnostics — coming back to your
    /// desk dismisses it the normal way, with a key or the trackpad.
    @discardableResult
    static func stop() -> Bool {
        LoginFramework.stopNow() == 0
    }
}

/// Where Drift's screensaver stands with macOS: installed, and selected.
///
/// Selection cannot be set programmatically — it lives in a binary plist inside
/// `~/Library/Application Support/com.apple.wallpaper/`, and writing it by hand would mean
/// rewriting the whole wallpaper configuration (see README). So Drift reads it and tells
/// you, rather than pretending it can fix it.
struct ScreenSaverInstallation: Equatable {

    var isInstalled: Bool
    var isSelected: Bool

    static let installedPath = ("~/Library/Screen Savers/Back Soon.saver" as NSString).expandingTildeInPath
    static let bundleName = "Back Soon.saver"
    private static let wallpaperIndexPath =
        ("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist" as NSString).expandingTildeInPath

    static func current() -> ScreenSaverInstallation {
        let installed = FileManager.default.fileExists(atPath: installedPath)
        return ScreenSaverInstallation(isInstalled: installed, isSelected: installed && selectionMentions())
    }

    /// A substring check over the wallpaper store rather than a parse.
    ///
    /// The file is a binary plist whose schema is Apple's and undocumented, and the
    /// selection itself is a nested binary plist holding a file URL — so a tolerant check
    /// that can be wrong in the harmless direction beats a strict parse that breaks on the
    /// next macOS release.
    ///
    /// Both spellings of the name are searched, because macOS records that URL
    /// percent-encoded: the store says `Back%20Soon.saver`, and looking only for
    /// `Back Soon.saver` reported "not selected" no matter what was actually selected.
    /// Matching the bundle's own name is unambiguous — nothing Apple ships is called this.
    private static func selectionMentions() -> Bool {
        guard let data = FileManager.default.contents(atPath: wallpaperIndexPath) else { return false }
        let encoded = bundleName.replacingOccurrences(of: " ", with: "%20")
        return [bundleName, encoded].contains { needle in
            data.range(of: Data(needle.utf8)) != nil
        }
    }

    var summary: String {
        switch (isInstalled, isSelected) {
        case (false, _):
            return "Drift’s screensaver is not installed. Run ./install-saver.sh, then choose “Back Soon” in System Settings › Screen Saver."
        case (true, false):
            return "Drift’s screensaver is installed but not selected. In System Settings › Screen Saver, under “Other”, choose “Back Soon” — not “Drift”, which is Apple’s own."
        case (true, true):
            return "Drift.saver is installed and selected."
        }
    }
}
