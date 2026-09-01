// A throwaway diagnostic: prints every calendar account EventKit can see, so you can tell
// whether a Google account is already reaching Drift via Calendar.app's own syncing.
//
// Deliberately standalone — it links EventKit and nothing of Drift's, so there is no
// @main clash with DriftAppMain and no AppKit run loop to get in the way.
//
//   ./tools/list-calendars.sh
//
// Expect a one-time Calendars permission prompt: this binary is unsigned and run from the
// terminal, so macOS attributes the request to the terminal, not to Drift.app. Granting it
// has no bearing on Drift.app's own separate grant.

import EventKit
import Foundation

@main
struct ListCalendars {

    /// Matches the window CalendarClient uses, so the event counts below are comparable.
    static let lookahead: TimeInterval = 24 * 60 * 60

    static func main() async {
        let store = EKEventStore()

        let before = EKEventStore.authorizationStatus(for: .event)
        print("Calendar authorisation before asking: \(describe(before))")

        let granted: Bool
        do {
            granted = try await store.requestFullAccessToEvents()
        } catch {
            print("Could not request Calendar access: \(error.localizedDescription)")
            exit(1)
        }

        guard granted else {
            let after = EKEventStore.authorizationStatus(for: .event)
            print("Calendar access was not granted (now: \(describe(after))).")
            if after == .notDetermined {
                // No prompt could be shown — usually because this ran somewhere that has
                // no window server session to put a dialog on.
                print("The permission dialog never appeared. Run ./tools/list-calendars.sh")
                print("directly in Terminal.app, where macOS can show the prompt.")
            } else {
                print("Allow it for your terminal in System Settings › Privacy & Security › Calendars,")
                print("then re-run. (Drift.app has its own separate grant.)")
            }
            exit(1)
        }

        // Sources can be stale on a freshly created store, and a just-granted permission
        // is exactly when that bites.
        store.refreshSourcesIfNecessary()

        let sources = store.sources.filter { !$0.calendars(for: .event).isEmpty }
        guard !sources.isEmpty else {
            print("Access granted, but there are no calendar accounts on this Mac.")
            print("Add one in System Settings › Internet Accounts.")
            exit(0)
        }

        let now = Date()
        let start = now.addingTimeInterval(-lookahead)
        let end = now.addingTimeInterval(lookahead)

        var sawGoogle = false

        for source in sources.sorted(by: { $0.title < $1.title }) {
            let calendars = Array(source.calendars(for: .event))
            let isGoogle = looksLikeGoogle(source)
            if isGoogle { sawGoogle = true }

            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
            let events = store.events(matching: predicate)
            let inProgress = events.filter { event in
                guard let s = event.startDate, let e = event.endDate else { return false }
                return s <= now && now < e && !event.isAllDay
            }

            print("")
            print("\(source.title)  [\(describe(source.sourceType))\(isGoogle ? " · Google" : "")]")
            print("  \(calendars.count) calendar\(calendars.count == 1 ? "" : "s"), "
                  + "\(events.count) event\(events.count == 1 ? "" : "s") in ±24h, "
                  + "\(inProgress.count) in progress now")
            for calendar in calendars.sorted(by: { $0.title < $1.title }) {
                print("    • \(calendar.title)")
            }
            for event in inProgress.sorted(by: { ($0.endDate ?? now) < ($1.endDate ?? now) }) {
                let title = (event.title ?? "").isEmpty ? "(untitled)" : event.title!
                let until = (event.endDate ?? now).formatted(date: .omitted, time: .shortened)
                print("    → in progress: \(title) until \(until)")
            }
        }

        print("")
        print(sawGoogle
              ? "A Google account is present, so Drift is already reading your Google events."
              : "No Google account found. Add one in System Settings › Internet Accounts.")
    }

    /// Google accounts arrive as CalDAV sources titled with the address, so the title is
    /// the only thing there is to go on.
    static func looksLikeGoogle(_ source: EKSource) -> Bool {
        let title = source.title.lowercased()
        guard source.sourceType == .calDAV || source.sourceType == .subscribed else { return false }
        return title.contains("gmail.com")
            || title.contains("googlemail")
            || title.contains("google")
    }

    static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not determined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "full access"
        case .writeOnly: return "write only"
        @unknown default: return "unknown"
        }
    }

    static func describe(_ type: EKSourceType) -> String {
        switch type {
        case .local: return "On this Mac"
        case .exchange: return "Exchange"
        case .calDAV: return "CalDAV"
        case .mobileMe: return "iCloud"
        case .subscribed: return "Subscribed"
        case .birthdays: return "Birthdays"
        @unknown default: return "Unknown"
        }
    }
}
