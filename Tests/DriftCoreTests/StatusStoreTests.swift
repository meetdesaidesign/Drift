import Foundation
import Testing
@testable import DriftCore

/// Builds a StatusStore wired to throwaway UserDefaults, a throwaway status.json and a
/// stubbed calendar read, so nothing here touches the real app's state or your calendar.
@MainActor
private struct Harness {
    let defaults: UserDefaults
    let suiteName: String
    let fileURL: URL
    let store: StatusStore

    init(
        fetchEvents: (@Sendable () async throws -> [CalendarEvent])? = nil,
        seed: ((UserDefaults) -> Void)? = nil
    ) {
        let id = UUID().uuidString
        suiteName = "co.drift.tests.\(id)"
        defaults = UserDefaults(suiteName: suiteName)!
        seed?(defaults)
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drift-tests-\(id)")
            .appendingPathComponent("status.json")
        store = StatusStore(
            defaults: defaults,
            sharedFile: SharedStatusFile(url: fileURL),
            fetchEvents: fetchEvents ?? { [] }
        )
    }

    /// A fresh store over the same defaults — stands in for relaunching the app.
    func reopened() -> StatusStore {
        StatusStore(
            defaults: defaults,
            sharedFile: SharedStatusFile(url: fileURL),
            fetchEvents: { [] }
        )
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

@Suite("Custom status persistence")
@MainActor
struct PersistenceTests {

    @Test("A custom status survives a restart")
    func customStatusSurvivesRestart() {
        let h = Harness()
        defer { h.tearDown() }

        let backAt = Date(timeIntervalSince1970: 1_700_003_600)
        h.store.updateCustomStatus(text: "Out for lunch", emoji: "🍜", returnTime: backAt)
        h.store.setSource(.custom)

        let reopened = h.reopened()
        #expect(reopened.customStatus.text == "Out for lunch")
        #expect(reopened.customStatus.emoji == "🍜")
        #expect(reopened.customStatus.returnTime == backAt)
        #expect(reopened.source == .custom)
    }

    @Test("Settings and the chosen source survive a restart")
    func settingsSurviveRestart() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.updateSettings {
            $0.fallbackText = "Not at my desk"
            $0.showReturnTime = false
            $0.idleActivationEnabled = true
            $0.idleActivationDelay = 240
        }
        h.store.setSource(.calendar)

        let reopened = h.reopened()
        #expect(reopened.settings.fallbackText == "Not at my desk")
        #expect(reopened.settings.showReturnTime == false)
        #expect(reopened.settings.idleActivationEnabled == true)
        #expect(reopened.settings.idleActivationDelay == 240)
        #expect(reopened.source == .calendar)
    }

    @Test("Presets seed on first launch and keep edits afterwards")
    func presetsSeedThenPersist() {
        let h = Harness()
        defer { h.tearDown() }

        #expect(h.store.presets.count == 6)
        #expect(h.store.presets.first?.text == "Out for lunch")

        var edited = h.store.presets
        edited[0].text = "Lunch, back soon"
        edited.append(DriftPreset(emoji: "🏃", text: "School run"))
        h.store.updatePresets(edited)

        let reopened = h.reopened()
        #expect(reopened.presets.count == 7)
        #expect(reopened.presets[0].text == "Lunch, back soon")
    }

    @Test("Applying a preset sets the status and switches to Custom")
    func applyingPreset() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.setSource(.calendar)
        h.store.applyPreset(DriftPreset(emoji: "🎧", text: "Focus time"))
        #expect(h.store.source == .custom)
        #expect(h.store.display().text == "Focus time")
        #expect(h.store.display().emoji == "🎧")
    }

    @Test("The published status.json round-trips — this is the screensaver's contract")
    func sharedFileRoundTrip() throws {
        let h = Harness()
        defer { h.tearDown() }

        h.store.updateCustomStatus(text: "In a meeting", emoji: "🗓️",
                                   returnTime: Date(timeIntervalSince1970: 1_700_003_600))
        h.store.setSource(.custom)
        h.store.publish(force: true)

        let payload = try SharedStatusFile(url: h.fileURL).read()
        #expect(payload.schema == SharedPayload.currentSchema)
        #expect(payload.display.text == "In a meeting")
        #expect(payload.display.emoji == "🗓️")
        #expect(payload.fallbackText == "Away from desk")
    }

    @Test("Private mode keeps the real status out of the file the screensaver reads")
    func privateModeNeverReachesDisk() throws {
        let h = Harness()
        defer { h.tearDown() }

        h.store.updateCustomStatus(text: "Dentist appointment", emoji: "🩺")
        h.store.updateSettings { $0.privateMode = true }
        h.store.publish(force: true)

        let raw = try String(contentsOf: h.fileURL, encoding: .utf8)
        #expect(raw.contains("Dentist") == false)
        #expect(raw.contains("Away from desk"))
    }

    @Test("A cached status left over from the Slack version is cleared, not resurrected")
    func retiredKeysAreCleared() {
        let h = Harness(seed: { defaults in
            let stale = DriftStatus(text: "Slack status from a previous version",
                                    emoji: "🍜", source: .custom)
            StatusStore.Keys.encode(stale, to: defaults, key: "drift.cachedSlackStatus")
        })
        defer { h.tearDown() }

        #expect(h.defaults.object(forKey: "drift.cachedSlackStatus") == nil)
        #expect(h.store.cachedCalendarStatus == nil)
    }
}

@Suite("Calendar failures and cached status")
@MainActor
struct CachedStatusTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Seeds a cached calendar status directly into defaults, standing in for "we read the
    /// calendar successfully earlier, and now the read is failing".
    private func seedCache(expiresAt: Date?) -> (UserDefaults) -> Void {
        { defaults in
            let cached = DriftStatus(
                text: "Design review", emoji: "🗓️",
                returnTime: expiresAt, expiresAt: expiresAt,
                source: .calendar, updatedAt: Date(timeIntervalSince1970: 1_699_999_000)
            )
            StatusStore.Keys.encode(cached, to: defaults, key: StatusStore.Keys.cachedCalendar)
            defaults.set(DriftStatus.Source.calendar.rawValue, forKey: StatusStore.Keys.source)
        }
    }

    @Test("Calendar read fails, cache still valid → the cached status is used")
    func failureWithValidCache() async {
        let h = Harness(
            fetchEvents: { throw CalendarSourceError.readFailed("EventKit unavailable") },
            seed: seedCache(expiresAt: now.addingTimeInterval(3600))
        )
        defer { h.tearDown() }

        await h.store.syncCalendar(now: now)
        #expect(h.store.display(now: now).text == "Design review")
        #expect(h.store.display(now: now).emoji == "🗓️")
        #expect(h.store.calendarAccess == .failing(
            CalendarSourceError.readFailed("EventKit unavailable").errorDescription!
        ))
    }

    @Test("Calendar read fails, cache expired → 'Away from desk'")
    func failureWithExpiredCache() async {
        let h = Harness(
            fetchEvents: { throw CalendarSourceError.readFailed("EventKit unavailable") },
            seed: seedCache(expiresAt: now.addingTimeInterval(-60))
        )
        defer { h.tearDown() }

        await h.store.syncCalendar(now: now)
        #expect(h.store.display(now: now).text == "Away from desk")
    }

    @Test("A valid cache goes stale on its own once the meeting ends, with no new read")
    func cacheExpiresWithoutResync() {
        let h = Harness(seed: seedCache(expiresAt: now.addingTimeInterval(600)))
        defer { h.tearDown() }

        #expect(h.store.display(now: now).text == "Design review")
        #expect(h.store.display(now: now.addingTimeInterval(1200)).text == "Away from desk")
    }

    @Test("Access denied is reported as denied, and the cache is still honoured")
    func accessDenied() async {
        let h = Harness(
            fetchEvents: { throw CalendarSourceError.accessDenied },
            seed: seedCache(expiresAt: now.addingTimeInterval(3600))
        )
        defer { h.tearDown() }

        await h.store.syncCalendar(now: now)
        #expect(h.store.calendarAccess == .denied)
        #expect(h.store.lastCalendarError?.contains("System Settings") == true)
        #expect(h.store.display(now: now).text == "Design review")
    }

    @Test("An empty calendar clears the cache rather than resurrecting an old meeting")
    func emptyCalendarClearsCache() async {
        let h = Harness(
            fetchEvents: { [] },
            seed: seedCache(expiresAt: now.addingTimeInterval(3600))
        )
        defer { h.tearDown() }

        await h.store.syncCalendar(now: now)
        #expect(h.store.cachedCalendarStatus == nil)
        #expect(h.store.display(now: now).text == "Away from desk")
        #expect(h.store.calendarAccess == .authorized)
    }

    @Test("A successful read replaces the cache and records the time")
    func successfulReadUpdatesCache() async {
        let h = Harness(
            fetchEvents: {
                [CalendarEvent(title: "Team lunch",
                               start: Date(timeIntervalSince1970: 1_699_999_400),
                               end: Date(timeIntervalSince1970: 1_700_003_000))]
            },
            seed: seedCache(expiresAt: now.addingTimeInterval(3600))
        )
        defer { h.tearDown() }

        await h.store.syncCalendar(now: now)
        #expect(h.store.cachedCalendarStatus?.text == "Team lunch")
        #expect(h.store.cachedCalendarStatus?.emoji == "🍜")
        #expect(h.store.lastSyncDate == now)
        #expect(h.store.display(now: now).text == "Team lunch")
    }
}
