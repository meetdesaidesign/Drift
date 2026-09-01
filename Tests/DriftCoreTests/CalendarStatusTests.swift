import Foundation
import Testing
@testable import DriftCore

// Note: these tests use swift-testing rather than XCTest because this Mac has
// Command Line Tools only, and XCTest.framework ships with Xcode.

@Suite("Calendar event interpretation")
struct CalendarStatusTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(
        _ title: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval,
        allDay: Bool = false,
        declined: Bool = false
    ) -> CalendarEvent {
        CalendarEvent(
            title: title,
            start: now.addingTimeInterval(startOffset),
            end: now.addingTimeInterval(endOffset),
            isAllDay: allDay,
            isDeclined: declined
        )
    }

    @Test("An in-progress meeting becomes the status, ending when the meeting does")
    func inProgressMeeting() throws {
        let status = try #require(CalendarStatus.status(
            from: [event("Design review", startOffset: -600, endOffset: 1800)], now: now
        ))
        #expect(status.text == "Design review")
        #expect(status.source == .calendar)
        #expect(status.expiresAt == now.addingTimeInterval(1800))
        #expect(status.returnTime == now.addingTimeInterval(1800))
        #expect(status.isExpired(at: now) == false)
        #expect(status.isExpired(at: now.addingTimeInterval(1801)))
    }

    @Test("Meetings that have not started or have already ended are ignored")
    func onlyInProgress() {
        #expect(CalendarStatus.status(from: [event("Later", startOffset: 600, endOffset: 1800)], now: now) == nil)
        #expect(CalendarStatus.status(from: [event("Earlier", startOffset: -3600, endOffset: -60)], now: now) == nil)
        #expect(CalendarStatus.status(from: [], now: now) == nil)
    }

    @Test("A meeting's end instant is not still in progress")
    func endIsExclusive() {
        #expect(CalendarStatus.status(from: [event("Ending now", startOffset: -600, endOffset: 0)], now: now) == nil)
    }

    @Test("All-day events are ignored — they are not a reason you left your desk")
    func allDayIgnored() {
        let events = [event("Q3 planning week", startOffset: -3600, endOffset: 36000, allDay: true)]
        #expect(CalendarStatus.status(from: events, now: now) == nil)
    }

    @Test("Declined invitations are ignored")
    func declinedIgnored() {
        let events = [event("Optional sync", startOffset: -60, endOffset: 1800, declined: true)]
        #expect(CalendarStatus.status(from: events, now: now) == nil)
    }

    @Test("When meetings overlap, the one ending soonest wins")
    func soonestEndingWins() throws {
        let events = [
            event("Long workshop", startOffset: -3600, endOffset: 7200),
            event("Quick standup", startOffset: -300, endOffset: 600),
            event("Medium meeting", startOffset: -600, endOffset: 3600),
        ]
        let status = try #require(CalendarStatus.status(from: events, now: now))
        #expect(status.text == "Quick standup")
    }

    @Test("Overlaps ending at the same time resolve deterministically, not at random")
    func stableTieBreak() throws {
        let events = [
            event("Beta", startOffset: -600, endOffset: 1800),
            event("Alpha", startOffset: -600, endOffset: 1800),
        ]
        let first = try #require(CalendarStatus.status(from: events, now: now))
        let second = try #require(CalendarStatus.status(from: events.reversed(), now: now))
        #expect(first.text == second.text)
    }

    @Test("An untitled event shows 'In a meeting' rather than a blank status")
    func untitledEvent() throws {
        let status = try #require(CalendarStatus.status(
            from: [event("   ", startOffset: -60, endOffset: 1800)], now: now
        ))
        #expect(status.text == "In a meeting")
        #expect(status.isBlank == false)
    }

    @Test("Emoji are inferred from the event title", arguments: [
        ("Team lunch", "🍜"),
        ("Coffee with Sam", "☕"),
        ("Focus time", "🎧"),
        ("1:1 with Alex", "📞"),
        ("Weekly sync", "📞"),
        ("Dentist appointment", "🩺"),
        ("All hands", "🗣️"),
        ("PTO", "🌴"),
        ("Sprint planning", "🗓️"),
    ])
    func emojiInference(title: String, expected: String) {
        #expect(CalendarEmoji.forTitle(title) == expected)
    }

    @Test("Emoji matching is on whole words, so it does not fire on substrings")
    func wordBoundaryMatching() {
        // "call" must not match inside "recalled", and "run" must not match "runway".
        #expect(CalendarEmoji.forTitle("Product recalled postmortem") == CalendarEmoji.fallback)
        #expect(CalendarEmoji.forTitle("Runway review") == "🗣️")
        #expect(CalendarEmoji.forTitle("Kickoff call") == "📞")
    }

    @Test("Calendar errors carry a message that says what to do about it")
    func errorMessages() {
        #expect(CalendarSourceError.accessDenied.errorDescription?.contains("System Settings") == true)
        #expect(CalendarSourceError.readFailed("disk on fire").errorDescription?.contains("disk on fire") == true)
    }
}
