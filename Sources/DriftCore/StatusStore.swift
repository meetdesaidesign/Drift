import Combine
import Foundation

/// Drift's single piece of state: the away session, if one is running, plus the two
/// choices the popover remembers between visits.
///
/// It persists to UserDefaults and republishes the resolved status to the file the
/// screensaver reads.
@MainActor
public final class StatusStore: ObservableObject {

    // MARK: Published state

    @Published public private(set) var settings: DriftSettings
    /// The running session, or `nil` when Drift is idle.
    @Published public private(set) var session: DriftSession?
    /// What the screen would show right now. The UI observes this rather than calling
    /// `display()`, which is a plain method and therefore invisible to SwiftUI.
    @Published public private(set) var currentDisplay: DisplayStatus
    /// Remembered so reopening the popover has your last choice already selected. Never
    /// acted on by itself — Drift does not start on its own.
    @Published public private(set) var lastStatus: StatusChoice?
    @Published public private(set) var lastDuration: DurationChoice?

    // MARK: Dependencies

    private let defaults: UserDefaults
    private let sharedFile: SharedStatusFile
    private var lastPublished: SharedPayload?

    public init(defaults: UserDefaults = .standard, sharedFile: SharedStatusFile = SharedStatusFile()) {
        self.defaults = defaults
        self.sharedFile = sharedFile

        let loadedSettings = Keys.decode(DriftSettings.self, from: defaults, key: Keys.settings) ?? DriftSettings()
        self.settings = loadedSettings
        self.lastStatus = Keys.decode(StatusChoice.self, from: defaults, key: Keys.lastStatus)
        self.lastDuration = Keys.decode(DurationChoice.self, from: defaults, key: Keys.lastDuration)
        // A session deliberately does not survive a restart. If Drift is not running,
        // nobody is being told you are away, so claiming a session on the next launch
        // would only resurrect yesterday's lunch.
        self.session = nil
        self.currentDisplay = resolveDisplay(session: nil, settings: loadedSettings)
        Keys.removeRetiredKeys(from: defaults)
    }

    // MARK: Derived state

    public var isActive: Bool { session != nil }

    public func display(now: Date = Date()) -> DisplayStatus {
        resolveDisplay(session: session, settings: settings, now: now)
    }

    // MARK: Remembering the choices

    /// Records a pick without acting on it, so closing the popover and coming back
    /// leaves you where you were.
    public func remember(status: StatusChoice) {
        lastStatus = status
        Keys.encode(status, to: defaults, key: Keys.lastStatus)
    }

    public func remember(duration: DurationChoice) {
        lastDuration = duration
        Keys.encode(duration, to: defaults, key: Keys.lastDuration)
    }

    // MARK: The session

    /// Starts a session and publishes it. Returns `false` — and starts nothing — if the
    /// choice has no text to show, which is the empty custom message case.
    @discardableResult
    public func start(status: StatusChoice, duration: DurationChoice, now: Date = Date()) -> Bool {
        guard let text = status.text else { return false }
        remember(status: status)
        remember(duration: duration)
        session = DriftSession(
            text: text,
            returnTime: duration.returnTime(from: now),
            startedAt: now
        )
        publish(now: now, force: true)
        return true
    }

    /// "+10 min". Extends from the return time if it is still ahead, and from now if it
    /// has already gone by — ten more minutes should always mean ten minutes from here.
    public func extend(byMinutes minutes: Int, now: Date = Date()) {
        guard var session else { return }
        session.returnTime = max(session.returnTime, now).addingTimeInterval(Double(minutes) * 60)
        self.session = session
        publish(now: now, force: true)
    }

    public func end(now: Date = Date()) {
        guard session != nil else { return }
        session = nil
        publish(now: now, force: true)
    }

    public func updateSettings(_ mutate: (inout DriftSettings) -> Void) {
        mutate(&settings)
        Keys.encode(settings, to: defaults, key: Keys.settings)
        publish()
    }

    // MARK: Publishing to the screensaver

    /// Writes the resolved status to `~/Library/Application Support/Drift/status.json`.
    /// Only writes when the payload actually changed, because the saver polls it.
    public func publish(now: Date = Date(), force: Bool = false) {
        let resolved = display(now: now)
        if currentDisplay != resolved { currentDisplay = resolved }

        let payload = SharedPayload(
            display: resolved,
            fallbackText: DriftSettings.idleText,
            sessionReturnTime: session?.returnTime,
            writtenAt: now
        )
        if !force, let lastPublished,
           lastPublished.display == payload.display,
           lastPublished.sessionReturnTime == payload.sessionReturnTime {
            return
        }
        lastPublished = payload
        do {
            try sharedFile.write(payload)
        } catch {
            // Nothing useful to do here — the screensaver keeps showing the last payload.
            NSLog("Drift: could not write shared status file: \(error.localizedDescription)")
        }
    }

    // MARK: UserDefaults keys

    enum Keys {
        static let settings = "drift.settings"
        static let lastStatus = "drift.lastStatus"
        static let lastDuration = "drift.lastDuration"

        /// Left over from earlier versions — the Slack status, then the calendar cache,
        /// editable presets and the custom-status draft. Cleared once on load so none of
        /// it can linger in preferences after the features that wrote it are gone.
        static let retired = [
            "drift.cachedSlackStatus",
            "drift.cachedCalendarStatus",
            "drift.customStatus",
            "drift.presets",
            "drift.source",
            "drift.lastSyncDate",
        ]

        static func removeRetiredKeys(from defaults: UserDefaults) {
            for key in retired where defaults.object(forKey: key) != nil {
                defaults.removeObject(forKey: key)
            }
        }

        static func encode<T: Encodable>(_ value: T, to defaults: UserDefaults, key: String) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value) else { return }
            defaults.set(data, forKey: key)
        }

        static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
            guard let data = defaults.data(forKey: key) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(type, from: data)
        }
    }
}
