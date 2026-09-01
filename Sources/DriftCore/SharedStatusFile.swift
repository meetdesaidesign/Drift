import Foundation

/// What Drift writes for the screensaver to read.
///
/// Only the *resolved* status goes in here, which means private mode and expiry are
/// already applied — the real status text never reaches this file when private mode
/// is on.
public struct SharedPayload: Codable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var display: DisplayStatus
    /// Carried so the saver can substitute correctly on its own if the payload has expired.
    public var fallbackText: String
    public var writtenAt: Date

    public init(display: DisplayStatus, fallbackText: String, writtenAt: Date = Date()) {
        self.schema = SharedPayload.currentSchema
        self.display = display
        self.fallbackText = fallbackText
        self.writtenAt = writtenAt
    }

    /// The saver's last line of defence: if Drift died while a status was live, the
    /// payload on disk can still go stale, so expiry is re-checked at render time.
    public func displayNow(_ now: Date) -> DisplayStatus {
        if let expiresAt = display.expiresAt, expiresAt <= now {
            return DisplayStatus(emoji: "", text: fallbackText, subtitle: nil, expiresAt: nil, updatedAt: now)
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
