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
    static let lookahead: TimeInterval = 24 * 60 * 60

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
    static func isDeclined(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return true }
        guard let attendees = event.attendees else { return false }
        return attendees.contains { $0.isCurrentUser && $0.participantStatus == .declined }
    }

    /// Fires when anything in the calendar database changes, so Drift can re-read
    /// immediately rather than waiting for the next two-minute tick.
    static let didChangeNotification = Notification.Name.EKEventStoreChanged

    // MARK: Accounts

    /// The calendar accounts Drift can see, for display in Settings.
    ///
    /// This exists to answer one recurring question — "does Drift see my Google
    /// calendar?" — without a debug tool. It does: `fetchEvents` passes `calendars: nil`,
    /// so every calendar in every account macOS syncs is already in scope, Google
    /// included. Showing the accounts makes that visible rather than something you have
    /// to take on trust.
    func accounts() -> [CalendarAccountInfo] {
        guard isAuthorized else { return [] }
        // A store built before access was granted can hold a stale source list, and
        // just-granted access is exactly when that bites.
        store.refreshSourcesIfNecessary()

        return store.sources.compactMap { source in
            let count = source.calendars(for: .event).count
            // Sources with no event calendars are noise here — a Contacts-only or
            // reminders-only account is not something Drift ever reads.
            guard count > 0 else { return nil }
            return CalendarAccountInfo(
                id: source.sourceIdentifier,
                title: source.title,
                kind: CalendarClient.kind(of: source),
                calendarCount: count
            )
        }
        .sorted { lhs, rhs in lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending }
    }

    /// A human label for the account type. Google and Exchange accounts both arrive as
    /// CalDAV, which is meaningless to read in Settings, so Google is picked out by its
    /// address — the only thing there is to go on.
    static func kind(of source: EKSource) -> String {
        switch source.sourceType {
        case .local: return "On this Mac"
        case .exchange: return "Exchange"
        case .mobileMe: return "iCloud"
        case .birthdays: return "Birthdays"
        case .subscribed:
            return isGoogle(source) ? "Google (subscribed)" : "Subscribed"
        case .calDAV:
            if isGoogle(source) { return "Google" }
            // iCloud is CalDAV under the skin, and reports itself by name.
            if source.title.localizedCaseInsensitiveContains("icloud") { return "iCloud" }
            return "CalDAV"
        @unknown default: return "Other"
        }
    }

    private static func isGoogle(_ source: EKSource) -> Bool {
        let title = source.title.lowercased()
        return title.contains("gmail.com") || title.contains("googlemail") || title.contains("google")
    }
}

// MARK: - Diagnostics

extension CalendarClient {

    /// A plain-text dump of everything EventKit hands Drift, and what Drift then does with
    /// it. Written only when the marker file exists — see `CalendarDiagnostics`.
    ///
    /// This exists because "Drift says nothing is on my calendar, but my calendar disagrees"
    /// has exactly three possible causes, and they need completely different fixes: the
    /// account is not in Calendar.app at all, the account is there but the event has not
    /// synced, or the event is there and one of Drift's own filters dropped it. Guessing
    /// between them is a waste of time; this tells you which.
    func diagnosticReport(now: Date = Date()) -> String {
        var out: [String] = []
        func line(_ s: String = "") { out.append(s) }

        let stamp = now.formatted(date: .abbreviated, time: .standard)
        line("Drift calendar diagnostics — \(stamp) (\(TimeZone.current.identifier))")
        line("Authorisation: \(CalendarClient.describe(authorizationStatus))")

        guard isAuthorized else {
            line()
            line("Not authorised, so there is nothing else to report.")
            return out.joined(separator: "\n") + "\n"
        }

        store.refreshSourcesIfNecessary()

        let sources = store.sources
        line("Sources: \(sources.count)")
        for source in sources {
            let calendars = Array(source.calendars(for: .event))
            line()
            line("  \(source.title)  [\(CalendarClient.kind(of: source))]  \(calendars.count) event calendar(s)")
            for calendar in calendars.sorted(by: { $0.title < $1.title }) {
                line("    • \(calendar.title)")
            }
        }

        let start = now.addingTimeInterval(-CalendarClient.lookahead)
        let end = now.addingTimeInterval(CalendarClient.lookahead)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)

        line()
        line("Events in ±24h across all calendars: \(events.count)")
        line()

        let sorted = events.sorted { ($0.startDate ?? now) < ($1.startDate ?? now) }
        for event in sorted {
            let title = (event.title ?? "").isEmpty ? "(untitled)" : event.title!
            let s = event.startDate?.formatted(date: .abbreviated, time: .shortened) ?? "?"
            let e = event.endDate?.formatted(date: .abbreviated, time: .shortened) ?? "?"
            line("  \(title)")
            line("    \(s) → \(e)")
            line("    calendar: \(event.calendar?.title ?? "?")  account: \(event.calendar?.source?.title ?? "?")")
            line("    allDay: \(event.isAllDay)  status: \(CalendarClient.describe(event.status))"
                 + "  declined(Drift): \(CalendarClient.isDeclined(event))")
            if let attendees = event.attendees, let me = attendees.first(where: { $0.isCurrentUser }) {
                line("    your RSVP: \(CalendarClient.describe(me.participantStatus))")
            }
            line("    verdict: \(CalendarClient.verdict(for: event, now: now))")
            line()
        }

        // Run the real rules, so the report ends with the same answer the UI shows.
        let mapped: [CalendarEvent] = sorted.compactMap { event in
            guard let s = event.startDate, let e = event.endDate else { return nil }
            return CalendarEvent(title: event.title ?? "", start: s, end: e,
                                 isAllDay: event.isAllDay, isDeclined: CalendarClient.isDeclined(event))
        }
        if let status = CalendarStatus.status(from: mapped, now: now) {
            line("Drift's answer: \(status.emoji) \(status.text), until "
                 + (status.expiresAt?.formatted(date: .omitted, time: .shortened) ?? "?"))
        } else {
            line("Drift's answer: nothing in progress.")
        }

        return out.joined(separator: "\n") + "\n"
    }

    /// Why an event did or did not become the status, in Drift's own terms.
    private static func verdict(for event: EKEvent, now: Date) -> String {
        guard let start = event.startDate, let end = event.endDate else { return "no dates — skipped" }
        if event.isAllDay { return "all-day — ignored by design" }
        if isDeclined(event) { return "declined or cancelled — ignored by design" }
        if now < start { return "has not started yet" }
        if end <= now { return "already finished" }
        return "IN PROGRESS — eligible to be your status"
    }

    private static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "full access"
        case .writeOnly: return "write only"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in process"
        @unknown default: return "unknown"
        }
    }
}

/// One calendar account, reduced to what Settings shows.
///
/// Lives in `DriftApp` rather than `DriftCore` on purpose: `DriftCore` is deliberately
/// EventKit-free so the screensaver bundle stays clean, and this is display-only data the
/// saver never reads.
struct CalendarAccountInfo: Identifiable, Hashable, Sendable {
    /// `EKSource.sourceIdentifier`.
    let id: String
    let title: String
    /// "Google", "iCloud", "Exchange", "On this Mac"…
    let kind: String
    let calendarCount: Int

    var isGoogle: Bool { kind.hasPrefix("Google") }
}
