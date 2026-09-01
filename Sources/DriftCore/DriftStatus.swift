import Foundation

/// A status Drift can display. This is the whole model: text, emoji, an optional
/// "back at" time, an optional expiry, where it came from, and when we learned it.
public struct DriftStatus: Codable, Equatable, Sendable {

    public enum Source: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Derived from the Mac's own Calendar — whatever meeting is in progress.
        case calendar
        case custom
        public var id: String { rawValue }
        public var label: String { self == .calendar ? "Calendar" : "Custom" }
    }

    public var text: String
    /// A literal unicode emoji ("🍜").
    public var emoji: String
    /// The "Back at" time shown under the status. Purely cosmetic — it does not expire anything.
    public var returnTime: Date?
    /// When this status stops being true. `nil` means it never expires.
    public var expiresAt: Date?
    public var source: Source
    public var updatedAt: Date

    public init(
        text: String,
        emoji: String = "",
        returnTime: Date? = nil,
        expiresAt: Date? = nil,
        source: Source,
        updatedAt: Date = Date()
    ) {
        self.text = text
        self.emoji = emoji
        self.returnTime = returnTime
        self.expiresAt = expiresAt
        self.source = source
        self.updatedAt = updatedAt
    }

    /// Expiry is inclusive: a status whose expiry has exactly arrived is already expired.
    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// A status with no text is treated as no status at all.
    public var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Usable means: we have one, it says something, and it has not expired.
    public func isUsable(at now: Date) -> Bool {
        !isBlank && !isExpired(at: now)
    }
}

/// What actually goes on screen. Resolution has already happened by this point:
/// expiry, blank statuses and private mode are all settled, so a `DisplayStatus`
/// is always safe to render as-is.
public struct DisplayStatus: Codable, Equatable, Sendable {
    public var emoji: String
    public var text: String
    /// e.g. "Back around 2:30 PM". Already respects the show-return-time setting.
    public var subtitle: String?
    /// Carried through so the screensaver can re-check expiry itself if Drift is not running.
    public var expiresAt: Date?
    public var updatedAt: Date

    public init(
        emoji: String = "",
        text: String,
        subtitle: String? = nil,
        expiresAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.emoji = emoji
        self.text = text
        self.subtitle = subtitle
        self.expiresAt = expiresAt
        self.updatedAt = updatedAt
    }
}

/// The single place every display rule lives. Kept pure so the tests can pin it down.
///
/// Rules, in order:
///  - private mode always wins and shows only the fallback text
///  - an expired status is never shown
///  - a blank status is never shown
///  - anything not shown becomes the fallback text ("Away from desk")
public func resolveDisplay(
    status: DriftStatus?,
    now: Date,
    settings: DriftSettings
) -> DisplayStatus {

    func fallback() -> DisplayStatus {
        DisplayStatus(emoji: "", text: settings.fallbackText, subtitle: nil, expiresAt: nil, updatedAt: now)
    }

    if settings.privateMode { return fallback() }
    guard let status, status.isUsable(at: now) else { return fallback() }

    let subtitle: String? = {
        guard settings.showReturnTime, let returnTime = status.returnTime else { return nil }
        return DriftFormat.returnLine(for: returnTime, now: now)
    }()

    return DisplayStatus(
        emoji: status.emoji,
        text: status.text,
        subtitle: subtitle,
        expiresAt: status.expiresAt,
        updatedAt: status.updatedAt
    )
}

public enum DriftFormat {

    /// "Back around 2:30 PM", or "Back around Tue 2:30 PM" when it is not today.
    public static func returnLine(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Back around \(time)"
        }
        let day = date.formatted(.dateTime.weekday(.abbreviated))
        return "Back around \(day) \(time)"
    }

    /// "just now" / "3 min ago" / "2:14 PM" — used for the last-sync line in Settings.
    public static func relativeSync(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 45 { return "just now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) min ago" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
