import Foundation
import Testing
@testable import DriftCore

/// Builds a StatusStore wired to throwaway UserDefaults and a throwaway status.json, so
/// nothing here touches the real app's state.
@MainActor
private struct Harness {
    let defaults: UserDefaults
    let suiteName: String
    let fileURL: URL
    let store: StatusStore

    init(seed: ((UserDefaults) -> Void)? = nil) {
        let id = UUID().uuidString
        suiteName = "co.drift.tests.\(id)"
        defaults = UserDefaults(suiteName: suiteName)!
        seed?(defaults)
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drift-tests-\(id)")
            .appendingPathComponent("status.json")
        store = StatusStore(defaults: defaults, sharedFile: SharedStatusFile(url: fileURL))
    }

    /// A fresh store over the same defaults — stands in for relaunching the app.
    func reopened() -> StatusStore {
        StatusStore(defaults: defaults, sharedFile: SharedStatusFile(url: fileURL))
    }

    func published() throws -> SharedPayload {
        try SharedStatusFile(url: fileURL).read()
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }
}

@Suite("Sessions")
@MainActor
struct SessionTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Starting a session publishes the status and the return time")
    func startPublishes() throws {
        let h = Harness()
        defer { h.tearDown() }

        #expect(h.store.isActive == false)
        #expect(h.store.start(status: .preset("lunch"), duration: .minutes(30), now: now))
        #expect(h.store.isActive)
        #expect(h.store.session?.text == "Out for lunch")
        #expect(h.store.session?.returnTime == now.addingTimeInterval(1800))

        let payload = try h.published()
        #expect(payload.schema == SharedPayload.currentSchema)
        #expect(payload.display.text == "Out for lunch")
        #expect(payload.display.returnTime == now.addingTimeInterval(1800))
        #expect(payload.fallbackText == "Away from desk")
    }

    @Test("An empty custom message starts nothing")
    func emptyCustomMessageStartsNothing() {
        let h = Harness()
        defer { h.tearDown() }

        #expect(h.store.start(status: .custom("   "), duration: .minutes(15), now: now) == false)
        #expect(h.store.isActive == false)
    }

    @Test("A custom message becomes the status, trimmed")
    func customMessageBecomesStatus() {
        let h = Harness()
        defer { h.tearDown() }

        #expect(h.store.start(status: .custom("  At the dentist "), duration: .minutes(45), now: now))
        #expect(h.store.session?.text == "At the dentist")
    }

    @Test("Ending a session publishes 'Away from desk'")
    func endPublishesFallback() throws {
        let h = Harness()
        defer { h.tearDown() }

        h.store.start(status: .preset("break"), duration: .minutes(10), now: now)
        h.store.end(now: now)
        #expect(h.store.isActive == false)

        let payload = try h.published()
        #expect(payload.display.text == "Away from desk")
        #expect(payload.display.returnTime == nil)
        #expect(payload.sessionReturnTime == nil)
    }

    @Test("+10 min extends from the return time while it is still ahead")
    func extendFromReturnTime() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.start(status: .preset("lunch"), duration: .minutes(30), now: now)
        h.store.extend(byMinutes: 10, now: now.addingTimeInterval(60))
        #expect(h.store.session?.returnTime == now.addingTimeInterval(1800 + 600))
    }

    @Test("+10 min on an overdue session means ten minutes from now, not from then")
    func extendFromNowWhenOverdue() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.start(status: .preset("lunch"), duration: .minutes(5), now: now)
        let late = now.addingTimeInterval(3600)
        h.store.extend(byMinutes: 10, now: late)
        #expect(h.store.session?.returnTime == late.addingTimeInterval(600))
    }

    @Test("Extending with no session running does nothing")
    func extendWithoutSession() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.extend(byMinutes: 10, now: now)
        #expect(h.store.isActive == false)
    }

    @Test("The return time is kept out of the display, but not out of the staleness guard")
    func hiddenReturnTimeStillGuarded() throws {
        let h = Harness()
        defer { h.tearDown() }

        h.store.updateSettings { $0.showReturnTime = false }
        h.store.start(status: .preset("meeting"), duration: .minutes(30), now: now)

        let payload = try h.published()
        #expect(payload.display.text == "In a meeting")
        #expect(payload.display.returnTime == nil)
        #expect(payload.sessionReturnTime == now.addingTimeInterval(1800))
    }
}

@Suite("What is remembered, and what is not")
@MainActor
struct PersistenceTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("The last status and duration survive a restart")
    func choicesSurviveRestart() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.remember(status: .preset("lunch"))
        h.store.remember(duration: .minutes(45))

        let reopened = h.reopened()
        #expect(reopened.lastStatus == .preset("lunch"))
        #expect(reopened.lastDuration == .minutes(45))
    }

    @Test("A custom message and a picked time are remembered too")
    func customChoicesSurviveRestart() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.start(status: .custom("Picking up the kids"), duration: .clock(hour: 17, minute: 15), now: now)

        let reopened = h.reopened()
        #expect(reopened.lastStatus == .custom("Picking up the kids"))
        #expect(reopened.lastDuration == .clock(hour: 17, minute: 15))
    }

    @Test("A running session does NOT survive a restart — Drift never resumes on its own")
    func sessionDoesNotSurviveRestart() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.start(status: .preset("lunch"), duration: .minutes(30), now: now)

        let reopened = h.reopened()
        #expect(reopened.isActive == false)
        #expect(reopened.currentDisplay.text == "Away from desk")
    }

    @Test("Settings survive a restart")
    func settingsSurviveRestart() {
        let h = Harness()
        defer { h.tearDown() }

        h.store.updateSettings { $0.showReturnTime = false }
        #expect(h.reopened().settings.showReturnTime == false)
    }

    @Test("State left by the calendar and preset versions is cleared, not resurrected")
    func retiredKeysAreCleared() {
        let h = Harness(seed: { defaults in
            for key in StatusStore.Keys.retired {
                defaults.set(Data("stale".utf8), forKey: key)
            }
        })
        defer { h.tearDown() }

        for key in StatusStore.Keys.retired {
            #expect(h.defaults.object(forKey: key) == nil)
        }
    }
}

@Suite("The screensaver's contract")
struct SharedPayloadTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("A live payload is shown as written, however overdue it is")
    func overduePayloadStillShows() {
        let back = now.addingTimeInterval(-2 * 60 * 60)
        let payload = SharedPayload(
            display: DisplayStatus(text: "Out for lunch", returnTime: back, updatedAt: now),
            sessionReturnTime: back,
            writtenAt: now
        )
        #expect(payload.displayNow(now).text == "Out for lunch")
        #expect(payload.displayNow(now).returnTime == back)
    }

    @Test("A payload left behind by a crash stops being believed after half a day")
    func staleGuard() {
        let back = now.addingTimeInterval(-13 * 60 * 60)
        let payload = SharedPayload(
            display: DisplayStatus(text: "Out for lunch", returnTime: back, updatedAt: now),
            sessionReturnTime: back,
            writtenAt: now
        )
        #expect(payload.displayNow(now).text == "Away from desk")
        #expect(payload.displayNow(now).returnTime == nil)
    }

    @Test("The guard still applies when the return time is hidden on screen")
    func staleGuardWithHiddenReturnTime() {
        let payload = SharedPayload(
            display: DisplayStatus(text: "In a meeting", returnTime: nil, updatedAt: now),
            sessionReturnTime: now.addingTimeInterval(-13 * 60 * 60),
            writtenAt: now
        )
        #expect(payload.displayNow(now).text == "Away from desk")
    }

    @Test("An idle payload has nothing to go stale")
    func idlePayload() {
        let payload = SharedPayload(display: DisplayStatus(text: "Away from desk", updatedAt: now))
        #expect(payload.displayNow(now.addingTimeInterval(86_400)).text == "Away from desk")
    }

    @Test("status.json round-trips through disk")
    func roundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drift-payload-\(UUID().uuidString)")
            .appendingPathComponent("status.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let file = SharedStatusFile(url: url)
        let back = now.addingTimeInterval(900)
        try file.write(SharedPayload(
            display: DisplayStatus(text: "On a break", returnTime: back, updatedAt: now),
            sessionReturnTime: back,
            writtenAt: now
        ))

        let read = try file.read()
        #expect(read.display.text == "On a break")
        #expect(read.display.returnTime == back)
        #expect(read.sessionReturnTime == back)
    }
}
