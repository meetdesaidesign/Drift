import AppKit

/// Starts the system screensaver on demand, and reports what macOS will do about locking
/// once it has.
///
/// Why the screensaver and not Drift's own window: the full-screen window lives in your
/// logged-in session, so while it is up the Mac is *not* locked, and it dismisses itself
/// the moment a real lock arrives (see `FullScreenPresenter`). The screensaver is the
/// other way round — macOS draws it *over* a locked session, so the installed
/// `Drift.saver` keeps showing your status while the Mac is genuinely locked behind it.
/// That makes the screensaver the only mechanism that does both at once.
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
                return "ScreenSaverEngine is missing from this Mac, so Drift cannot start the screensaver."
            case .launchFailed(let message):
                return "Could not start the screensaver: \(message)"
            case .didNotStart:
                return "macOS did not start the screensaver. Check that a screensaver is chosen in System Settings › Screen Saver."
            }
        }
    }

    static let engineURL = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")

    /// Processes that mean "the screensaver is up". `ScreenSaverEngine` is the engine
    /// itself; `legacyScreenSaver` is the sandboxed host that draws a third-party `.saver`
    /// such as Drift's, and on some macOS versions that is the one that shows up.
    private static let screenSaverBundleIDs: Set<String> = [
        "com.apple.ScreenSaver.Engine",
        "com.apple.ScreenSaver.Engine.legacyScreenSaver",
        "com.apple.legacyScreenSaver",
        "com.apple.legacyScreenSaver.x86",
    ]

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard let identifier = app.bundleIdentifier else { return false }
            return screenSaverBundleIDs.contains(identifier)
        }
    }

    /// Launches the engine, then goes back and checks that it is still there.
    ///
    /// The second look is the point. Whether launching `ScreenSaverEngine` still activates
    /// the screensaver has changed between macOS releases, and its failure mode is to
    /// start and immediately exit rather than to return an error — so a launch that
    /// "succeeded" proves nothing. Drift waits and looks instead of assuming.
    static func start() async throws {
        guard FileManager.default.fileExists(atPath: engineURL.path) else {
            throw Failure.engineMissing
        }
        if isRunning { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false

        do {
            _ = try await NSWorkspace.shared.openApplication(at: engineURL, configuration: configuration)
        } catch {
            throw Failure.launchFailed(error.localizedDescription)
        }

        // Long enough for the engine to take the screen, and long enough for the
        // start-then-quit failure to have happened.
        try? await Task.sleep(for: .milliseconds(1500))
        guard isRunning else { throw Failure.didNotStart }
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
    private static let wallpaperIndexPath =
        ("~/Library/Application Support/com.apple.wallpaper/Store/Index.plist" as NSString).expandingTildeInPath

    static func current() -> ScreenSaverInstallation {
        let installed = FileManager.default.fileExists(atPath: installedPath)
        return ScreenSaverInstallation(isInstalled: installed, isSelected: installed && selectionMentionsDrift())
    }

    /// A substring check over the wallpaper store rather than a parse.
    ///
    /// The file is a binary plist whose schema is Apple's and undocumented, and it is read
    /// only to decide which of two sentences to show — so a tolerant check that can be
    /// wrong in the harmless direction beats a strict parse that breaks on the next macOS
    /// release. It matches this bundle's own path: macOS ships a screensaver called Drift
    /// too, and being sure which one is selected is the entire point of this check.
    private static func selectionMentionsDrift() -> Bool {
        guard let data = FileManager.default.contents(atPath: wallpaperIndexPath) else { return false }
        return data.range(of: Data("Screen Savers/Back Soon.saver".utf8)) != nil
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
