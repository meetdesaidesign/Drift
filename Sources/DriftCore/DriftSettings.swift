import Foundation

/// Everything Drift lets you configure, which is deliberately almost nothing.
public struct DriftSettings: Codable, Equatable, Sendable {

    /// Whether the "Back around 1:35 PM" line appears under the status on screen.
    public var showReturnTime: Bool = true

    /// Shown whenever no session is running. Fixed, not a setting: an away sign with
    /// nobody away should say the plainest possible thing.
    public static let idleText = "Away from desk"

    public init() {}
}

/// The four fixed statuses. Not editable, and not stored: a "Back soon" sign with a
/// preset editor is no longer a sign.
///
/// `label` is the button ("Lunch"); `text` is what goes on the screen ("Out for lunch").
public struct StatusPreset: Identifiable, Equatable, Sendable {

    public let id: String
    public let label: String
    public let text: String

    public static let all: [StatusPreset] = [
        StatusPreset(id: "lunch", label: "Lunch", text: "Out for lunch"),
        StatusPreset(id: "break", label: "Break", text: "On a break"),
        StatusPreset(id: "meeting", label: "Meeting", text: "In a meeting"),
        StatusPreset(id: "away", label: "Away", text: "Away from desk"),
    ]

    public static func preset(id: String) -> StatusPreset? {
        all.first { $0.id == id }
    }
}

/// What you picked in the top half of the popover.
public enum StatusChoice: Codable, Equatable, Sendable {
    case preset(String)
    case custom(String)

    /// The longest custom message Drift will take. Long enough for a real sentence,
    /// short enough to stay readable at 80pt from across a room.
    public static let customLimit = 48

    /// What goes on screen, or `nil` if this choice cannot produce anything to show —
    /// an unknown preset id, or a custom message that is only whitespace.
    public var text: String? {
        switch self {
        case .preset(let id):
            return StatusPreset.preset(id: id)?.text
        case .custom(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Truncates a typed message to `customLimit`. Cuts on grapheme boundaries, so an
    /// emoji or accented character is never split in half. Whitespace is left alone
    /// here — it is trimmed in `text`, so a trailing space can still be typed through.
    public static func sanitise(custom message: String) -> String {
        String(message.prefix(customLimit))
    }
}

/// How long you will be away.
///
/// `clock` is the Custom time picker's answer. It is stored as an hour and a minute
/// rather than a `Date` so that restoring it tomorrow means tomorrow's 3 PM, not
/// yesterday's.
public enum DurationChoice: Codable, Equatable, Sendable, Hashable {
    case minutes(Int)
    case clock(hour: Int, minute: Int)

    /// The chips, in the order they appear.
    public static let presets: [DurationChoice] = [5, 10, 15, 20, 30, 45, 60].map { .minutes($0) }

    /// "5m", "30m", "1 hr", or "1:35 PM" for a picked time.
    public func label(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch self {
        case .minutes(let minutes) where minutes < 60:
            return "\(minutes)m"
        case .minutes(let minutes) where minutes % 60 == 0:
            return "\(minutes / 60) hr"
        case .minutes(let minutes):
            return "\(minutes / 60) hr \(minutes % 60)m"
        case .clock:
            return DriftFormat.time(returnTime(from: now, calendar: calendar), now: now, calendar: calendar)
        }
    }

    /// When you will be back.
    ///
    /// A picked clock time that has already gone by today means the same time tomorrow —
    /// picking 8:00 at 9 PM is a morning, not a time machine.
    public func returnTime(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .minutes(let minutes):
            return now.addingTimeInterval(Double(minutes) * 60)
        case .clock(let hour, let minute):
            guard let today = calendar.date(
                bySettingHour: min(max(hour, 0), 23),
                minute: min(max(minute, 0), 59),
                second: 0,
                of: now
            ) else {
                return now.addingTimeInterval(15 * 60)
            }
            if today > now { return today }
            return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        }
    }

    /// Builds a `.clock` from what the time picker handed back.
    public static func clock(from date: Date, calendar: Calendar = .current) -> DurationChoice {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return .clock(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
    }

    public var isCustom: Bool {
        if case .clock = self { return true }
        return false
    }
}
