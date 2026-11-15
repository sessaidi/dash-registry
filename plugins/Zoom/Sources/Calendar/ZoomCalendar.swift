import AppKit
import DashKit
import EventKit
import Foundation

/// A calendar event with a Zoom link: what the Upcoming Meetings widget lists and what names a
/// recording.
struct CalendarMeeting: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String
    /// The Zoom link from the event's URL, location or notes.
    let joinURL: URL?

    /// Within `lead` before its start, until its end.
    func isHappening(at now: Date = .now, lead: TimeInterval = 10 * 60) -> Bool {
        start.addingTimeInterval(-lead) <= now && now < end
    }

    var json: JSONValue {
        ["id": .string(id), "title": .string(title), "start": .string(start.formatted(.iso8601)), "end": .string(end.formatted(.iso8601)),
         "calendar": .string(calendar), "join_url": joinURL.map { .string($0.absoluteString) } ?? .null]
    }
}

/// Zoom meetings from the Mac's calendars (Google, Outlook or iCloud as synced to Calendar), read
/// through EventKit: no Zoom account or app needed, only the calendar permission.
@MainActor
final class ZoomCalendar {
    enum Access: Equatable { case notAsked, granted, denied }

    private let store = EKEventStore()

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    /// Asks macOS once (the prompt's text is Dash.app's: plugins run in its process).
    func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Events from `now` to `hours` ahead that have a Zoom link (all of them with `onlyZoom` off),
    /// soonest first. Events already over and all-day events are left out.
    func upcoming(hours: Double = 24, onlyZoom: Bool = true, now: Date = .now) -> [CalendarMeeting] {
        guard access == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-3 * 3600), end: now.addingTimeInterval(hours * 3600), calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now && $0.status != .canceled }
            .compactMap { event in
                let link = Self.zoomLink(in: [event.url?.absoluteString, event.location, event.notes].compactMap { $0 })
                guard link != nil || !onlyZoom else { return nil }
                return CalendarMeeting(id: event.calendarItemExternalIdentifier ?? event.eventIdentifier, title: event.title ?? "Meeting",
                                       start: event.startDate, end: event.endDate, calendar: event.calendar.title, joinURL: link)
            }
            .sorted { $0.start < $1.start }
    }

    /// Posts `onChange` when calendars change (a new invite, a moved meeting).
    func observeChanges(_ onChange: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
            MainActor.assumeIsolated { onChange() }
        }
    }

    /// The first Zoom meeting link in these texts: `https://<host>.zoom.us/j/…`, `/my/…`, `/w/…`,
    /// or a `zoommtg://` link.
    nonisolated static func zoomLink(in texts: [String]) -> URL? {
        let pattern = #"(?:https://[A-Za-z0-9.-]*zoom\.us/(?:j|my|w|s)/[^\s<>"')\]]+|zoommtg://[^\s<>"')\]]+)"#
        for text in texts {
            if let range = text.range(of: pattern, options: .regularExpression), let url = URL(string: String(text[range])) { return url }
        }
        return nil
    }

    /// Opens the meeting in the Zoom app directly (`zoommtg://…/join?confno=…&pwd=…`) when the link
    /// is a `/j/` link, else as is (Zoom's page then opens the app).
    nonisolated static func appURL(for link: URL) -> URL {
        guard link.scheme == "https", let host = link.host(), link.pathComponents.count >= 3, link.pathComponents[1] == "j" else { return link }
        var components = URLComponents()
        components.scheme = "zoommtg"
        components.host = host
        components.path = "/join"
        var items = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: link.pathComponents[2])]
        if let password = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "pwd" })?.value {
            items.append(URLQueryItem(name: "pwd", value: password))
        }
        components.queryItems = items
        return components.url ?? link
    }

    /// Joins in the Zoom app, or the browser when the app isn't installed.
    nonisolated static func join(_ link: URL) {
        let app = appURL(for: link)
        Task { @MainActor in
            if app.scheme == "zoommtg", NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
                NSWorkspace.shared.open(app)
            } else {
                NSWorkspace.shared.open(link)
            }
        }
    }
}
