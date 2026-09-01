import Foundation

/// An opt-in calendar dump, for when Drift and your calendar disagree.
///
/// Off unless the marker file exists, so a normal install writes nothing and reads nothing
/// extra. Marker rather than an environment variable on purpose: Drift is launched as a GUI
/// app, where there is no shell to set a variable in.
///
///   touch ~/Library/Application\ Support/Drift/.debug-calendar
///   open build/Drift.app                      # relaunch
///   cat ~/Library/Application\ Support/Drift/calendar-debug.txt
///
/// Delete the marker to turn it back off.
enum CalendarDiagnostics {

    static let markerName = ".debug-calendar"
    static let reportName = "calendar-debug.txt"

    /// Reuses the same directory as `status.json` — the one place Drift already owns, and
    /// one that stays readable from outside the app.
    private static var directory: URL { SharedStatusFile.defaultDirectory() }

    static var markerURL: URL { directory.appendingPathComponent(markerName) }
    static var reportURL: URL { directory.appendingPathComponent(reportName) }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: markerURL.path)
    }

    /// Writes the report, or does nothing at all if the marker is absent.
    ///
    /// Deliberately silent on failure: this is a diagnostic, and a diagnostic that can
    /// break the app it is diagnosing is worse than no diagnostic.
    static func writeIfEnabled(using client: CalendarClient, now: Date = Date()) {
        guard isEnabled else { return }
        let report = client.diagnosticReport(now: now)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? report.data(using: .utf8)?.write(to: reportURL, options: .atomic)
    }
}
