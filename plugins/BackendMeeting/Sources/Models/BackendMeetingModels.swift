import DashKit
import Foundation
import SwiftData

/// A generated backend meeting report: the highlights of one cycle.
@Model
final class BackendReport {
    @Attribute(.unique) var id: UUID
    /// First day covered (start of day).
    var start: Date
    /// Last moment covered; the next report starts here.
    var end: Date
    /// The cycle the user picked (1–10 weeks); 0 when it ran "since the last report".
    var cycleWeeks: Int
    var markdown: String
    var createdAt: Date

    init(start: Date, end: Date, cycleWeeks: Int, markdown: String) {
        id = UUID()
        self.start = start
        self.end = end
        self.cycleWeeks = cycleWeeks
        self.markdown = markdown
        createdAt = .now
    }

    var rangeLabel: String { ReportRange(start: start, end: end).label }
}

/// The days a report covers.
struct ReportRange: Equatable, Sendable {
    var start: Date
    var end: Date

    /// "3 Nov → 14 Nov 2026".
    var label: String {
        "\(start.formatted(.dateTime.day().month(.abbreviated))) → \(end.formatted(.dateTime.day().month(.abbreviated).year()))"
    }

    /// YYYY-MM-DD in the user's calendar.
    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    var startDay: String { Self.day(start) }
    var endDay: String { Self.day(end) }

    /// Since the previous report's end when there is one (capped at ten weeks), else the last
    /// `cycleWeeks` weeks; `sinceLastReport` false always uses the cycle.
    static func make(cycleWeeks: Int, sinceLastReport: Bool, lastEnd: Date?, now: Date = .now, calendar: Calendar = .current) -> ReportRange {
        let weeks = min(max(cycleWeeks, 1), 10)
        let cycleStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -7 * weeks, to: now) ?? now)
        guard sinceLastReport, let lastEnd, lastEnd < now else { return ReportRange(start: cycleStart, end: now) }
        let earliest = calendar.startOfDay(for: calendar.date(byAdding: .day, value: -70, to: now) ?? now)
        return ReportRange(start: max(calendar.startOfDay(for: lastEnd), earliest), end: now)
    }
}

/// One pull request the user authored, from GitHub search.
struct AuthoredPull: Equatable, Sendable {
    enum State: String, Sendable { case merged, open, draft, closed }

    let repo: String
    let number: Int
    let title: String
    let state: State
    let url: String
    let updated: String
    /// Ticket keys in the title (LAF-5689), to group PRs that share one.
    var tickets: [String] { Self.tickets(in: title) }

    static func tickets(in text: String) -> [String] {
        text.matches(of: /[A-Z][A-Z0-9]+-\d+/).map { String($0.output) }
    }

    /// A GitHub search item (`/search/issues`), or nil when it isn't a pull request.
    init?(item: JSONValue) {
        guard let pull = item["pull_request"], pull != .null, let number = item["number"]?.int else { return nil }
        let repository = item["repository_url"]?.string ?? ""
        repo = repository.split(separator: "/").suffix(2).joined(separator: "/")
        self.number = number
        title = item["title"]?.string ?? ""
        url = item["html_url"]?.string ?? ""
        updated = item["updated_at"]?.string ?? ""
        if let merged = pull["merged_at"]?.string, !merged.isEmpty {
            state = .merged
        } else if item["state"]?.string == "open" {
            state = item["draft"]?.bool == true ? .draft : .open
        } else {
            state = .closed
        }
    }

    var json: JSONValue {
        ["repo": .string(repo), "number": .number(Double(number)), "title": .string(title), "state": .string(state.rawValue),
         "tickets": .array(tickets.map(JSONValue.string)), "updated": .string(updated)]
    }
}
