import EventKit
import Foundation

/// Reads the Mac's Calendar via EventKit.
///
/// This lives in the app, not in DriftCore, on purpose: it keeps EventKit and the calendar
/// permission prompt out of the screensaver bundle, which has no need for either — the
/// saver only ever reads the file the app publishes.
final class CalendarClient: @unchecked Sendable {

    private let store = EKEventStore()
    /// How far ahead to look. Only in-progress events become a status, but a window is
    /// still needed for the EventKit predicate, and a small one keeps the query cheap.
    private static let lookahead: TimeInterval = 24 * 60 * 60

    var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    /// Triggers the one-time macOS permission prompt. Returns whether access was granted.
    @discardableResult
    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    /// Fetches events overlapping now, mapped to DriftCore's plain `CalendarEvent`.
    func fetchEvents(now: Date = Date()) async throws -> [CalendarEvent] {
        switch authorizationStatus {
        case .notDetermined:
            throw CalendarSourceError.accessNotDetermined
        case .denied, .restricted:
            throw CalendarSourceError.accessDenied
        case .fullAccess:
            break
        case .writeOnly:
            // Write-only access cannot read events, so it is no use to Drift.
            throw CalendarSourceError.accessDenied
        @unknown default:
            throw CalendarSourceError.accessDenied
        }

        // Start the window in the past so a long meeting already under way is included.
        let start = now.addingTimeInterval(-CalendarClient.lookahead)
        let end = now.addingTimeInterval(CalendarClient.lookahead)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)

        // events(matching:) does not throw — it returns an empty array on failure — so
        // there is nothing to catch here.
        let events = store.events(matching: predicate)

        return events.compactMap { event in
            guard let startDate = event.startDate, let endDate = event.endDate else { return nil }
            return CalendarEvent(
                title: event.title ?? "",
                start: startDate,
                end: endDate,
                isAllDay: event.isAllDay,
                isDeclined: CalendarClient.isDeclined(event)
            )
        }
    }

    /// True when you have declined the invitation — a declined meeting should not become
    /// your status.
    private static func isDeclined(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return true }
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    /// Fires when anything in the calendar database changes, so Drift can re-read
    /// immediately rather than waiting for the next two-minute tick.
    static let didChangeNotification = Notification.Name.EKEventStoreChanged
}
