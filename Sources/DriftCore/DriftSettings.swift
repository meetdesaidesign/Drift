import Foundation

public struct DriftSettings: Codable, Equatable, Sendable {

    /// Which source Drift uses when it starts up.
    public var defaultSource: DriftStatus.Source = .custom
    /// Shown whenever there is nothing valid to show.
    public var fallbackText: String = DriftSettings.defaultFallbackText
    public var showReturnTime: Bool = true
    /// When on, Drift shows only `fallbackText` — the real status is never rendered
    /// and never written to the shared file the screensaver reads.
    public var privateMode: Bool = false
    /// Only relevant to the full-screen fallback window, not the real screensaver.
    /// Off by default: with a working .saver, two things firing on idle is silly.
    public var idleActivationEnabled: Bool = false
    public var idleActivationDelay: TimeInterval = 180

    public static let defaultFallbackText = "Away from desk"

    public init() {}
}

public struct DriftPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var emoji: String
    public var text: String

    public init(id: UUID = UUID(), emoji: String, text: String) {
        self.id = id
        self.emoji = emoji
        self.text = text
    }

    public static let starters: [DriftPreset] = [
        DriftPreset(emoji: "🍜", text: "Out for lunch"),
        DriftPreset(emoji: "📞", text: "On a call"),
        DriftPreset(emoji: "🗓️", text: "In a meeting"),
        DriftPreset(emoji: "🎧", text: "Focus time"),
        DriftPreset(emoji: "🚶", text: "Stepped out"),
        DriftPreset(emoji: "☕", text: "Back soon"),
    ]
}
