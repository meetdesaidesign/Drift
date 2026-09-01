import Foundation
import Testing
@testable import DriftCore

@Suite("Display rules: expiry, blanks and private mode")
struct DisplayRuleTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func settings(
        fallback: String = DriftSettings.defaultFallbackText,
        showReturnTime: Bool = true,
        privateMode: Bool = false
    ) -> DriftSettings {
        var s = DriftSettings()
        s.fallbackText = fallback
        s.showReturnTime = showReturnTime
        s.privateMode = privateMode
        return s
    }

    @Test("An expired status is never displayed")
    func expiredIsNeverShown() {
        let status = DriftStatus(
            text: "Out for lunch", emoji: "🍜",
            expiresAt: now.addingTimeInterval(-1), source: .custom
        )
        let display = resolveDisplay(status: status, now: now, settings: settings())
        #expect(display.text == "Away from desk")
        #expect(display.emoji == "")
        #expect(display.subtitle == nil)
    }

    @Test("Expiry is inclusive — the exact expiry instant is already expired")
    func expiryIsInclusive() {
        let status = DriftStatus(text: "On a call", emoji: "📞", expiresAt: now, source: .custom)
        #expect(status.isExpired(at: now))
        #expect(resolveDisplay(status: status, now: now, settings: settings()).text == "Away from desk")
    }

    @Test("An unexpired status is displayed as written")
    func unexpiredIsShown() {
        let status = DriftStatus(
            text: "Out for lunch", emoji: "🍜",
            returnTime: now.addingTimeInterval(1800),
            expiresAt: now.addingTimeInterval(3600),
            source: .custom
        )
        let display = resolveDisplay(status: status, now: now, settings: settings())
        #expect(display.text == "Out for lunch")
        #expect(display.emoji == "🍜")
        #expect(display.subtitle?.hasPrefix("Back around") == true)
    }

    @Test("A status with no expiry never expires")
    func noExpiryNeverExpires() {
        let status = DriftStatus(text: "Focus time", emoji: "🎧", source: .custom)
        #expect(resolveDisplay(status: status, now: .distantFuture, settings: settings()).text == "Focus time")
    }

    @Test("No status at all falls back")
    func nilStatusFallsBack() {
        #expect(resolveDisplay(status: nil, now: now, settings: settings()).text == "Away from desk")
    }

    @Test("A blank status falls back — this is an untitled, unmatched event")
    func blankStatusFallsBack() {
        let blank = DriftStatus(text: "   ", emoji: "🍜", source: .calendar)
        #expect(resolveDisplay(status: blank, now: now, settings: settings()).text == "Away from desk")
    }

    @Test("Private mode always shows the fallback, never the real status")
    func privateModeHidesEverything() {
        let status = DriftStatus(
            text: "Therapy appointment", emoji: "🩺",
            returnTime: now.addingTimeInterval(3600), source: .custom
        )
        let display = resolveDisplay(status: status, now: now, settings: settings(privateMode: true))
        #expect(display.text == "Away from desk")
        #expect(display.emoji == "")
        #expect(display.subtitle == nil)
    }

    @Test("A custom fallback text is respected everywhere the fallback is used")
    func customFallback() {
        let s = settings(fallback: "Not here")
        #expect(resolveDisplay(status: nil, now: now, settings: s).text == "Not here")
        let expired = DriftStatus(text: "x", expiresAt: now.addingTimeInterval(-5), source: .custom)
        #expect(resolveDisplay(status: expired, now: now, settings: s).text == "Not here")
    }

    @Test("Turning off the return time hides the subtitle but keeps the status")
    func returnTimeToggle() {
        let status = DriftStatus(
            text: "Stepped out", emoji: "🚶",
            returnTime: now.addingTimeInterval(900), source: .custom
        )
        #expect(resolveDisplay(status: status, now: now, settings: settings(showReturnTime: false)).subtitle == nil)
        #expect(resolveDisplay(status: status, now: now, settings: settings(showReturnTime: true)).subtitle != nil)
    }

    @Test("The shared payload re-checks expiry itself, in case Drift is not running")
    func payloadReExpires() {
        let display = DisplayStatus(
            emoji: "🍜", text: "Out for lunch", subtitle: "Back around 2:30 PM",
            expiresAt: now.addingTimeInterval(60), updatedAt: now
        )
        let payload = SharedPayload(display: display, fallbackText: "Away from desk", writtenAt: now)
        #expect(payload.displayNow(now).text == "Out for lunch")
        #expect(payload.displayNow(now.addingTimeInterval(120)).text == "Away from desk")
        #expect(payload.displayNow(now.addingTimeInterval(120)).emoji == "")
    }
}
