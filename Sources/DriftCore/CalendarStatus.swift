import Foundation

/// A calendar event, reduced to just what Drift needs.
///
/// Deliberately not an `EKEvent`: keeping this a plain value type means every rule below
/// is testable without EventKit, without calendar permission, and without a calendar. The
/// EventKit-touching code lives in the app (`CalendarClient`), not here — which also keeps
/// EventKit out of the screensaver bundle, where it has no business being.
public struct CalendarEvent: Equatable, Sendable {
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// Used to skip declined invitations, which should not become your status.
    public var isDeclined: Bool

    public init(title: String, start: Date, end: Date, isAllDay: Bool = false, isDeclined: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isDeclined = isDeclined
    }

    public func isInProgress(at now: Date) -> Bool {
        start <= now && now < end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public enum CalendarStatus {

    /// Turns the calendar into "what I'm doing right now", or `nil` if that is nothing.
    ///
    /// Rules:
    ///  - only events actually in progress count;
    ///  - all-day events are ignored — "Q3 planning week" is not a reason you are away
    ///    from your desk, and it would sit there all day;
    ///  - declined invitations are ignored;
    ///  - untitled events fall back to "In a meeting" rather than showing a blank status;
    ///  - when several events overlap, the one ending soonest wins, since that is the one
    ///    you are most likely actually in.
    ///
    /// The event's end time becomes both the return time and the expiry, so the status
    /// clears itself when the meeting does.
    public static func status(from events: [CalendarEvent], now: Date) -> DriftStatus? {
        let candidates = events.filter { event in
            event.isInProgress(at: now) && !event.isAllDay && !event.isDeclined
        }
        guard let event = candidates.min(by: { lhs, rhs in
            // Ending soonest wins; duration then title keep the choice stable when two
            // events end at the same moment.
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
            return lhs.title < rhs.title
        }) else { return nil }

        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = title.isEmpty ? "In a meeting" : title

        return DriftStatus(
            text: text,
            emoji: CalendarEmoji.forTitle(text),
            returnTime: event.end,
            expiresAt: event.end,
            source: .calendar,
            updatedAt: now
        )
    }
}

/// Picks an emoji from the event title.
///
/// The large emoji is a load-bearing part of Drift's look, so a calendar event with no
/// emoji of its own gets a reasonable one inferred from its title. Matching is on whole
/// words so "call" does not fire on "recalled" and "1:1" does not fire on "11:00".
public enum CalendarEmoji {

    public static let fallback = "🗓️"

    /// Ordered most specific first — the first rule that matches wins.
    private static let rules: [(emoji: String, keywords: [String])] = [
        ("🍜", ["lunch", "dinner", "breakfast", "brunch"]),
        ("☕", ["coffee", "tea break"]),
        ("🎧", ["focus", "deep work", "heads down", "no meetings", "work block"]),
        ("📞", ["call", "1:1", "one on one", "1-1", "sync", "catch up", "catchup", "check in", "check-in"]),
        ("🎤", ["interview", "screening"]),
        ("🚶", ["walk", "break", "errand", "commute"]),
        ("✈️", ["flight", "travel", "airport"]),
        ("🩺", ["doctor", "dentist", "appointment", "therapy", "clinic"]),
        ("🎉", ["birthday", "party", "celebration", "social", "happy hour"]),
        ("🏋️", ["gym", "workout", "training", "yoga", "run"]),
        ("🧑‍🏫", ["workshop", "training session", "onboarding", "demo"]),
        ("🗣️", ["all hands", "all-hands", "town hall", "standup", "stand-up", "retro", "review"]),
        ("🛠️", ["oncall", "on-call", "incident", "deploy", "release"]),
        ("🌴", ["pto", "vacation", "holiday", "annual leave", "ooo", "out of office"]),
    ]

    public static func forTitle(_ title: String) -> String {
        let haystack = " " + normalise(title) + " "
        for rule in rules {
            for keyword in rule.keywords where haystack.contains(" " + normalise(keyword) + " ") {
                return rule.emoji
            }
        }
        return fallback
    }

    /// Lowercases and reduces everything that is not a letter, digit or colon to a single
    /// space, so word-boundary matching works regardless of punctuation.
    private static func normalise(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ":"))
        let scalars = s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}

/// Why a calendar read did not produce events. Kept in DriftCore, rather than alongside
/// the EventKit code, so `StatusStore` can map it to user-facing state without importing
/// EventKit itself.
public enum CalendarSourceError: Error, Equatable, LocalizedError {
    case accessNotDetermined
    case accessDenied
    case readFailed(String)

    public var errorDescription: String? {
        switch self {
        case .accessNotDetermined:
            return "Drift has not asked for Calendar access yet."
        case .accessDenied:
            return "Drift cannot read your Calendar. Allow it in System Settings › Privacy & Security › Calendars."
        case .readFailed(let message):
            return "Could not read the Calendar: \(message)"
        }
    }
}
