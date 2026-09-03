import Foundation
import Testing
@testable import DriftCore

// Note: these tests use swift-testing rather than XCTest because this Mac has
// Command Line Tools only, and XCTest.framework ships with Xcode.

@Suite("Display rules")
struct DisplayRuleTests {

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func settings(showReturnTime: Bool = true) -> DriftSettings {
        var s = DriftSettings()
        s.showReturnTime = showReturnTime
        return s
    }

    @Test("A running session is displayed as written, with its return time")
    func sessionIsShown() {
        let session = DriftSession(text: "Out for lunch", returnTime: now.addingTimeInterval(1800), startedAt: now)
        let display = resolveDisplay(session: session, settings: settings(), now: now)
        #expect(display.text == "Out for lunch")
        #expect(display.returnTime == now.addingTimeInterval(1800))
    }

    @Test("No session shows 'Away from desk' and no return time")
    func noSessionFallsBack() {
        let display = resolveDisplay(session: nil, settings: settings(), now: now)
        #expect(display.text == "Away from desk")
        #expect(display.returnTime == nil)
    }

    @Test("A blank session is treated as no session at all")
    func blankSessionFallsBack() {
        let session = DriftSession(text: "   ", returnTime: now.addingTimeInterval(600), startedAt: now)
        #expect(session.isBlank)
        #expect(resolveDisplay(session: session, settings: settings(), now: now).text == "Away from desk")
    }

    @Test("Turning off the return time hides it but keeps the status")
    func returnTimeToggle() {
        let session = DriftSession(text: "On a break", returnTime: now.addingTimeInterval(900), startedAt: now)
        #expect(resolveDisplay(session: session, settings: settings(showReturnTime: false), now: now).returnTime == nil)
        #expect(resolveDisplay(session: session, settings: settings(showReturnTime: false), now: now).text == "On a break")
        #expect(resolveDisplay(session: session, settings: settings(), now: now).returnTime != nil)
    }

    @Test("A session that has run past its return time is still a session")
    func overdueSessionKeepsShowing() {
        let session = DriftSession(text: "Out for lunch", returnTime: now.addingTimeInterval(-600), startedAt: now)
        #expect(session.isOverdue(at: now))
        // The estimate passing is not a reason to stop showing the status.
        #expect(resolveDisplay(session: session, settings: settings(), now: now).text == "Out for lunch")
    }
}

@Suite("Wording")
struct FormatTests {

    /// The calendar is pinned to UTC so "is it still today?" has a fixed answer here,
    /// whatever the machine's time zone is.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test("A future return time reads 'Back at' in the popover and 'Back around' on screen")
    func futureReturnTime() {
        let back = now.addingTimeInterval(1800)
        #expect(DriftFormat.backAt(back, now: now, calendar: calendar).hasPrefix("Back at "))
        #expect(DriftFormat.backAround(back, now: now, calendar: calendar).hasPrefix("Back around "))
    }

    @Test("A return time that has passed is replaced, never shown as an outdated time")
    func overdueWording() {
        let past = now.addingTimeInterval(-60)
        #expect(DriftFormat.backAt(past, now: now, calendar: calendar) == "Expected back shortly")
        #expect(DriftFormat.backAround(past, now: now, calendar: calendar) == "Expected back shortly")
        // The exact instant counts as passed — a return time of "now" is not news.
        #expect(DriftFormat.backAround(now, now: now, calendar: calendar) == "Expected back shortly")
    }

    @Test("A return time on another day carries the weekday, so it cannot be misread")
    func otherDayCarriesWeekday() {
        let tomorrow = now.addingTimeInterval(20 * 60 * 60)
        let line = DriftFormat.backAround(tomorrow, now: now, calendar: calendar)
        #expect(line.contains(tomorrow.formatted(.dateTime.weekday(.abbreviated))))
    }
}

@Suite("Durations")
struct DurationTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    /// Mid-morning, so "3:30 PM" is still ahead and "8:00 AM" is behind.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2024, month: 6, day: 12, hour: 10, minute: 15))!
    }

    @Test("The chips are the seven the popover shows, labelled short")
    func chipLabels() {
        #expect(DurationChoice.presets.count == 7)
        let labels = DurationChoice.presets.map { $0.label(now: now, calendar: calendar) }
        #expect(labels == ["5m", "10m", "15m", "20m", "30m", "45m", "1 hr"])
    }

    @Test("A minutes choice returns that many minutes from now")
    func minutesFromNow() {
        #expect(DurationChoice.minutes(20).returnTime(from: now) == now.addingTimeInterval(1200))
    }

    @Test("A picked time later today is that time today")
    func clockLaterToday() {
        let back = DurationChoice.clock(hour: 15, minute: 30).returnTime(from: now, calendar: calendar)
        #expect(calendar.dateComponents([.hour, .minute], from: back).hour == 15)
        #expect(calendar.isDate(back, inSameDayAs: now))
    }

    @Test("A picked time that has already gone by today means tomorrow, not a time machine")
    func clockAlreadyPassed() {
        let back = DurationChoice.clock(hour: 8, minute: 0).returnTime(from: now, calendar: calendar)
        #expect(back > now)
        #expect(calendar.isDate(back, inSameDayAs: now) == false)
        #expect(calendar.dateComponents([.hour], from: back).hour == 8)
    }

    @Test("A picked time round-trips through the date the picker hands back")
    func clockFromDate() {
        let picked = calendar.date(bySettingHour: 16, minute: 45, second: 0, of: now)!
        #expect(DurationChoice.clock(from: picked, calendar: calendar) == .clock(hour: 16, minute: 45))
    }
}

@Suite("Statuses")
struct StatusChoiceTests {

    @Test("The four presets are fixed, and each has its own screen wording")
    func presets() {
        #expect(StatusPreset.all.map(\.label) == ["Lunch", "Break", "Meeting", "Away"])
        #expect(StatusChoice.preset("lunch").text == "Out for lunch")
        #expect(StatusChoice.preset("meeting").text == "In a meeting")
        #expect(StatusChoice.preset("nonsense").text == nil)
    }

    @Test("A custom message is trimmed, and an empty one is not a status")
    func customMessages() {
        #expect(StatusChoice.custom("  Waiting for a delivery  ").text == "Waiting for a delivery")
        #expect(StatusChoice.custom("    ").text == nil)
        #expect(StatusChoice.custom("").text == nil)
    }

    @Test("A custom message is capped at a length that still reads across a room")
    func customLimit() {
        let long = String(repeating: "a", count: 200)
        #expect(StatusChoice.sanitise(custom: long).count == StatusChoice.customLimit)
        // Cut on grapheme boundaries, so a multi-scalar character is never split.
        let flags = String(repeating: "🇮🇳", count: 60)
        #expect(StatusChoice.sanitise(custom: flags).count == StatusChoice.customLimit)
    }
}
