import Combine
import Foundation

/// Whether Drift can actually read the Calendar, which is a permission question rather
/// than a connection one — there is no network involved.
public enum CalendarAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    /// Access was granted but the last read failed.
    case failing(String)
}

/// Drift's single piece of state. Owns the custom status, the cached Calendar status, the
/// settings and the presets; persists them to UserDefaults; and republishes the resolved
/// status to the file the screensaver reads.
@MainActor
public final class StatusStore: ObservableObject {

    // MARK: Published state

    @Published public private(set) var settings: DriftSettings
    @Published public private(set) var customStatus: DriftStatus
    @Published public private(set) var cachedCalendarStatus: DriftStatus?
    @Published public private(set) var presets: [DriftPreset]
    @Published public private(set) var source: DriftStatus.Source
    @Published public private(set) var calendarAccess: CalendarAccess = .notDetermined
    @Published public private(set) var lastSyncDate: Date?
    @Published public private(set) var lastCalendarError: String?
    @Published public private(set) var isSyncing = false
    /// The resolved status, republished whenever anything changes or a status expires.
    /// The UI observes this rather than calling `display()`, which is a plain method and
    /// therefore invisible to SwiftUI.
    @Published public private(set) var currentDisplay: DisplayStatus = DisplayStatus(text: DriftSettings.defaultFallbackText)

    // MARK: Dependencies

    private let defaults: UserDefaults
    private let sharedFile: SharedStatusFile
    /// Supplies the events currently in the Mac's Calendar.
    ///
    /// Injected rather than built here for two reasons: it keeps EventKit — and the
    /// calendar permission prompt — out of DriftCore and out of the screensaver bundle,
    /// and it lets the tests simulate a denied permission or a read failure with no
    /// calendar involved. `DriftApp` passes the real `CalendarClient`; the default
    /// returns nothing.
    private let fetchEvents: @Sendable () async throws -> [CalendarEvent]

    private var ticker: Task<Void, Never>?
    private var lastPublished: DisplayStatus?

    public static let calendarSyncInterval: TimeInterval = 120
    private static let tickInterval: TimeInterval = 15

    public init(
        defaults: UserDefaults = .standard,
        sharedFile: SharedStatusFile = SharedStatusFile(),
        fetchEvents: @escaping @Sendable () async throws -> [CalendarEvent] = { [] }
    ) {
        self.defaults = defaults
        self.sharedFile = sharedFile
        self.fetchEvents = fetchEvents

        let loadedSettings = Keys.decode(DriftSettings.self, from: defaults, key: Keys.settings) ?? DriftSettings()
        self.settings = loadedSettings
        self.presets = Keys.decode([DriftPreset].self, from: defaults, key: Keys.presets) ?? DriftPreset.starters
        self.customStatus = Keys.decode(DriftStatus.self, from: defaults, key: Keys.customStatus)
            ?? DriftStatus(text: "", emoji: "", source: .custom)
        self.cachedCalendarStatus = Keys.decode(DriftStatus.self, from: defaults, key: Keys.cachedCalendar)
        self.source = (defaults.string(forKey: Keys.source).flatMap(DriftStatus.Source.init(rawValue:)))
            ?? loadedSettings.defaultSource
        self.lastSyncDate = defaults.object(forKey: Keys.lastSync) as? Date
        self.currentDisplay = resolveDisplay(
            status: self.source == .calendar ? self.cachedCalendarStatus : self.customStatus,
            now: Date(), settings: self.settings
        )
        Keys.removeRetiredKeys(from: defaults)
    }

    // MARK: Derived state

    /// The status currently selected by the source picker, before any rules are applied.
    public var activeStatus: DriftStatus? {
        source == .calendar ? cachedCalendarStatus : customStatus
    }

    public func display(now: Date = Date()) -> DisplayStatus {
        resolveDisplay(status: activeStatus, now: now, settings: settings)
    }

    // MARK: Mutations

    public func setSource(_ newSource: DriftStatus.Source) {
        source = newSource
        defaults.set(newSource.rawValue, forKey: Keys.source)
        publish()
    }

    public func updateCustomStatus(
        text: String? = nil,
        emoji: String? = nil,
        returnTime: Date?? = nil,
        expiresAt: Date?? = nil
    ) {
        if let text { customStatus.text = text }
        if let emoji { customStatus.emoji = emoji }
        if let returnTime { customStatus.returnTime = returnTime }
        if let expiresAt { customStatus.expiresAt = expiresAt }
        customStatus.source = .custom
        customStatus.updatedAt = Date()
        persistCustomStatus()
        publish()
    }

    public func applyPreset(_ preset: DriftPreset) {
        customStatus.emoji = preset.emoji
        customStatus.text = preset.text
        customStatus.source = .custom
        customStatus.updatedAt = Date()
        setSource(.custom)
        persistCustomStatus()
        publish()
    }

    public func clearCustomStatus() {
        customStatus = DriftStatus(text: "", emoji: "", source: .custom)
        persistCustomStatus()
        publish()
    }

    public func updateSettings(_ mutate: (inout DriftSettings) -> Void) {
        mutate(&settings)
        Keys.encode(settings, to: defaults, key: Keys.settings)
        publish()
    }

    public func updatePresets(_ newPresets: [DriftPreset]) {
        presets = newPresets
        Keys.encode(presets, to: defaults, key: Keys.presets)
    }

    private func persistCustomStatus() {
        Keys.encode(customStatus, to: defaults, key: Keys.customStatus)
    }

    // MARK: Calendar

    /// Reads the Calendar and caches whatever meeting is in progress.
    ///
    /// The offline/failure rule lives here: if the read fails, the cached status is left
    /// alone, so it keeps being used right up until the meeting's end time — at which
    /// point `resolveDisplay` swaps in the fallback text on its own.
    public func syncCalendar(now: Date = Date()) async {
        isSyncing = true
        defer { isSyncing = false }

        do {
            let events = try await fetchEvents()
            cachedCalendarStatus = CalendarStatus.status(from: events, now: now)
            if let cachedCalendarStatus {
                Keys.encode(cachedCalendarStatus, to: defaults, key: Keys.cachedCalendar)
            } else {
                // Nothing in progress — clear the cache so an old meeting is not resurrected.
                defaults.removeObject(forKey: Keys.cachedCalendar)
            }
            lastSyncDate = now
            defaults.set(now, forKey: Keys.lastSync)
            lastCalendarError = nil
            calendarAccess = .authorized
        } catch let error as CalendarSourceError {
            lastCalendarError = error.errorDescription
            switch error {
            case .accessDenied: calendarAccess = .denied
            case .accessNotDetermined: calendarAccess = .notDetermined
            case .readFailed: calendarAccess = .failing(error.errorDescription ?? "Calendar read failed")
            }
        } catch {
            lastCalendarError = error.localizedDescription
            calendarAccess = .failing(error.localizedDescription)
        }
        publish(now: now)
    }

    // MARK: Publishing to the screensaver

    /// Writes the resolved status to `~/Library/Application Support/Drift/status.json`.
    /// Only writes when the resolved payload actually changed, because the saver polls it.
    public func publish(now: Date = Date(), force: Bool = false) {
        let resolved = display(now: now)
        if currentDisplay != resolved { currentDisplay = resolved }
        if !force, let lastPublished, lastPublished == resolved { return }
        lastPublished = resolved
        let payload = SharedPayload(display: resolved, fallbackText: settings.fallbackText, writtenAt: now)
        do {
            try sharedFile.write(payload)
        } catch {
            // Nothing useful to do here — the screensaver just keeps showing the last
            // payload, and the fallback window reads state directly from this store.
            NSLog("Drift: could not write shared status file: \(error.localizedDescription)")
        }
    }

    // MARK: Tickers

    /// One timer drives two things: republishing (so an expiring status flips to
    /// "Away from desk" on its own) and the two-minute Calendar re-read.
    public func startTickers() {
        ticker?.cancel()
        let ticksPerSync = Int((StatusStore.calendarSyncInterval / StatusStore.tickInterval).rounded())
        ticker = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(StatusStore.tickInterval))
                if Task.isCancelled { return }
                guard let self else { return }
                tick += 1
                self.publish()
                if tick % ticksPerSync == 0 {
                    await self.syncCalendar()
                }
            }
        }
    }

    public func stopTickers() {
        ticker?.cancel()
        ticker = nil
    }

    // MARK: UserDefaults keys

    enum Keys {
        static let settings = "drift.settings"
        static let presets = "drift.presets"
        static let customStatus = "drift.customStatus"
        static let cachedCalendar = "drift.cachedCalendarStatus"
        static let source = "drift.source"
        static let lastSync = "drift.lastSyncDate"

        /// Left over from the Slack-based version. Cleared once on load so a stale
        /// cached Slack status cannot linger in preferences.
        static let retired = ["drift.cachedSlackStatus"]

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
