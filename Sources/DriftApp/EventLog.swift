import Foundation

/// A short rolling log of what Drift actually did, at
/// `~/Library/Application Support/Drift/events.log`.
///
/// Drift has no window to report trouble in, and on this Mac the unified log is out of
/// reach without Full Disk Access — so an intermittent failure leaves nothing behind to
/// look at, and "it works sometimes" is impossible to answer. Twenty or so lines of plain
/// text fixes that. It records what Drift did, never what you typed: statuses and custom
/// messages are not written here.
enum EventLog {

    private static let maximumLines = 60
    private static var url: URL { SharedStatusFile.defaultDirectory().appendingPathComponent("events.log") }

    static func append(_ message: String) {
        let stamp = Date().formatted(date: .numeric, time: .standard)
        let line = "\(stamp)  \(message)\n"
        let directory = SharedStatusFile.defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var lines = (try? String(contentsOf: url, encoding: .utf8))?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init) ?? []
        lines.append(line.trimmingCharacters(in: .newlines))
        if lines.count > maximumLines { lines.removeFirst(lines.count - maximumLines) }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
