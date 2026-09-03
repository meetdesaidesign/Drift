import Foundation

/// What Drift writes for the screensaver to read.
///
/// Only the *resolved* status goes in here, so the screensaver never has a rule to
/// apply — it reads this and draws it.
public struct SharedPayload: Codable, Sendable {
    public static let currentSchema = 2

    /// How long after the return time a payload stops being believed.
    ///
    /// A running session never expires — that is the point of Drift. This guard is only
    /// for the case where Drift stopped running without ending its session (a crash, a
    /// force-quit): without it, `status.json` would claim you were at lunch indefinitely,
    /// and every idle screensaver from then on would say so.
    public static let staleAfter: TimeInterval = 12 * 60 * 60

    public var schema: Int
    public var display: DisplayStatus
    /// What to show when there is nothing to show.
    public var fallbackText: String
    /// The live session's return time, present even when the return time is hidden on
    /// screen. Used only by the staleness guard below.
    public var sessionReturnTime: Date?
    public var writtenAt: Date

    public init(
        display: DisplayStatus,
        fallbackText: String = DriftSettings.idleText,
        sessionReturnTime: Date? = nil,
        writtenAt: Date = Date()
    ) {
        self.schema = SharedPayload.currentSchema
        self.display = display
        self.fallbackText = fallbackText
        self.sessionReturnTime = sessionReturnTime
        self.writtenAt = writtenAt
    }

    /// The saver's last line of defence — see `staleAfter`.
    public func displayNow(_ now: Date) -> DisplayStatus {
        let reference = sessionReturnTime ?? display.returnTime
        if let reference, now.timeIntervalSince(reference) > SharedPayload.staleAfter {
            return DisplayStatus(text: fallbackText, returnTime: nil, updatedAt: now)
        }
        return display
    }
}

/// Reads and writes `~/Library/Application Support/Drift/status.json`.
///
/// The path is built from `getpwuid(getuid())` rather than `FileManager`, and that is
/// not incidental: inside the screensaver's sandbox, `FileManager`'s
/// `.applicationSupportDirectory` resolves to the process *container*
/// (~/Library/Containers/…/Data/Library/Application Support), which is not where Drift
/// writes. The real home path is readable there thanks to legacyScreenSaver's
/// read-only-"/" entitlement, so resolving it by hand is what makes this work.
public struct SharedStatusFile: Sendable {

    public let url: URL

    public init(url: URL? = nil) {
        self.url = url ?? SharedStatusFile.defaultURL()
    }

    public static func defaultDirectory() -> URL {
        let home: String
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Drift", isDirectory: true)
    }

    public static func defaultURL() -> URL {
        defaultDirectory().appendingPathComponent("status.json")
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Atomic so the saver, which polls this file, never sees a half-written status.
    public func write(_ payload: SharedPayload) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try SharedStatusFile.encoder().encode(payload)
        try data.write(to: url, options: .atomic)
    }

    public func read() throws -> SharedPayload {
        let data = try Data(contentsOf: url)
        return try SharedStatusFile.decoder().decode(SharedPayload.self, from: data)
    }

    /// Non-throwing read for the saver, which has nowhere useful to report an error to.
    public func readIfAvailable() -> SharedPayload? {
        try? read()
    }

    public func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    public func delete() {
        try? FileManager.default.removeItem(at: url)
    }
}
