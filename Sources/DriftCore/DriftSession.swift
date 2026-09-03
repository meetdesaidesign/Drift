import Foundation

/// One away session: what you are doing, and when you expect to be back.
///
/// This is Drift's whole model. There is no expiry and no source: a session begins when
/// you press Start Drift and ends when you come back. The return time is an estimate
/// shown on screen — it never ends the session, because a lunch that runs long is still
/// a lunch.
public struct DriftSession: Codable, Equatable, Sendable {

    /// What goes on the screen — "Out for lunch", or whatever you typed.
    public var text: String
    /// When you said you would be back.
    public var returnTime: Date
    public var startedAt: Date

    public init(text: String, returnTime: Date, startedAt: Date = Date()) {
        self.text = text
        self.returnTime = returnTime
        self.startedAt = startedAt
    }

    /// A session with no text is treated as no session at all.
    public var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The estimate has passed. Not a reason to stop — only a reason to stop showing a
    /// time that is no longer true.
    public func isOverdue(at now: Date) -> Bool { returnTime <= now }
}

/// What actually goes on screen. Resolution has already happened by this point, so a
/// `DisplayStatus` is always safe to render as-is.
///
/// The return time is carried as a `Date` rather than a formatted string on purpose: the
/// screensaver re-renders the line itself, so "Back around 1:35 PM" becomes "Expected
/// back shortly" when the time passes, even with nothing driving it.
public struct DisplayStatus: Codable, Equatable, Sendable {

    public var text: String
    /// `nil` when there is no session, or when the return time is switched off in Settings.
    public var returnTime: Date?
    public var updatedAt: Date

    public init(text: String, returnTime: Date? = nil, updatedAt: Date = Date()) {
        self.text = text
        self.returnTime = returnTime
        self.updatedAt = updatedAt
    }
}

/// The single place every display rule lives. Kept pure so the tests can pin it down.
///
/// Rules, in order:
///  - no session, or a blank one, shows "Away from desk";
///  - the return time is shown only when Settings says so.
public func resolveDisplay(
    session: DriftSession?,
    settings: DriftSettings,
    now: Date = Date()
) -> DisplayStatus {
    guard let session, !session.isBlank else {
        return DisplayStatus(text: DriftSettings.idleText, returnTime: nil, updatedAt: now)
    }
    return DisplayStatus(
        text: session.text,
        returnTime: settings.showReturnTime ? session.returnTime : nil,
        updatedAt: now
    )
}

public enum DriftFormat {

    /// Shown instead of a return time that has already gone by. Drift would rather say
    /// nothing precise than something wrong.
    public static let overdue = "Expected back shortly"

    /// "1:35 PM", or "Tue 1:35 PM" when it is not today. Uses the Mac's locale and
    /// 12/24-hour setting.
    public static func time(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        guard calendar.isDate(date, inSameDayAs: now) else {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return time
    }

    /// "Back at 1:35 PM" — the popover.
    public static func backAt(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        date <= now ? overdue : "Back at \(time(date, now: now, calendar: calendar))"
    }

    /// "Back around 1:35 PM" — the screen. Softer wording, because it is read from
    /// across a room by someone deciding whether to wait.
    public static func backAround(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        date <= now ? overdue : "Back around \(time(date, now: now, calendar: calendar))"
    }
}
