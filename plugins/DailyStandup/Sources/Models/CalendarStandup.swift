import DashKit
import Foundation

/// The standup as the calendar has it, read from the Zoom plugin's `zoom_upcoming_meetings`.
struct CalendarStandup: Codable, Equatable, Sendable {
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?

    init(title: String, start: Date, end: Date, joinURL: URL?) {
        self.title = title
        self.start = start
        self.end = end
        self.joinURL = joinURL
    }

    /// One meeting of `zoom_upcoming_meetings` (ISO 8601 dates).
    init?(_ json: JSONValue) {
        let dates = ISO8601DateFormatter()
        guard let title = json["title"]?.string, let start = json["start"]?.string.flatMap(dates.date(from:)),
              let end = json["end"]?.string.flatMap(dates.date(from:)) else { return nil }
        self.init(title: title, start: start, end: end, joinURL: json["join_url"]?.string.flatMap(URL.init(string:)))
    }
}
