import DashKit
import Foundation
import SwiftData

/// One working day's standup: your update (what you did since the last standup, what's next,
/// what blocks you), and on Zoom days the report of the meeting (who spoke, each person's
/// update, blockers, action items).
@Model
final class StandupDay {
    /// yyyy-MM-dd
    @Attribute(.unique) var day: String
    var date: Date
    /// Your update, as JSON (`StandupUpdate`).
    var updateData: Data
    var preparedAt: Date?
    /// What the update was built from (commits, PRs, tickets…), as JSON, for references.
    var evidenceData: Data
    /// Whether this day's standup is on Zoom (transcribed and reported).
    var onZoom: Bool
    var meetingID: String
    /// The meeting report, as JSON (`MeetingReport`).
    var reportData: Data
    var reportedAt: Date?
    var notePath: String

    init(day: String, date: Date, onZoom: Bool) {
        self.day = day
        self.date = date
        self.onZoom = onZoom
        updateData = Data("{}".utf8)
        evidenceData = Data("{}".utf8)
        meetingID = ""
        reportData = Data("{}".utf8)
        notePath = ""
    }

    var update: StandupUpdate? {
        get { try? JSONDecoder().decode(StandupUpdate.self, from: updateData) }
        set { updateData = (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8) }
    }

    var report: MeetingReport? {
        get { try? JSONDecoder().decode(MeetingReport.self, from: reportData) }
        set { reportData = (try? JSONEncoder().encode(newValue)) ?? Data("{}".utf8) }
    }
}

/// Something blocking someone, carried from day to day until resolved.
@Model
final class StandupBlocker {
    @Attribute(.unique) var id: UUID
    var text: String
    var owner: String
    /// Where it shows: a ticket key, a PR, a workspace…
    var reference: String
    var since: Date
    var lastMentioned: Date
    var resolvedAt: Date?

    init(text: String, owner: String, reference: String = "") {
        id = UUID()
        self.text = text
        self.owner = owner
        self.reference = reference
        since = .now
        lastMentioned = .now
    }

    var daysOpen: Int { max(0, Calendar.current.dateComponents([.day], from: since, to: resolvedAt ?? .now).day ?? 0) }
}

struct StandupItem: Codable, Hashable, Sendable {
    var text: String
    /// The ticket it's about ("LAF-5680"), when there is one.
    var ticket: String?
    /// Commit SHAs, PR numbers, ticket keys… that show it.
    var refs: [String]
    /// For today's items, the kind of next step: fix, continue, waiting, review, start, other.
    var kind: String?

    static func icon(_ kind: String?) -> String {
        switch kind {
        case "fix": "wrench.and.screwdriver"
        case "continue": "arrow.forward.circle"
        case "waiting": "hourglass"
        case "review": "eye"
        case "start": "plus.circle"
        default: "circle"
        }
    }

    static func label(_ kind: String?) -> String? {
        switch kind {
        case "fix": "Fix"
        case "continue": "Continue"
        case "waiting": "Waiting"
        case "review": "Review"
        case "start": "Start"
        default: nil
        }
    }
}

struct StandupUpdate: Codable, Hashable, Sendable {
    var yesterday: [StandupItem]
    var today: [StandupItem]
    var blockers: [StandupItem]

    /// Ready to paste in Slack or say aloud.
    var text: String {
        func section(_ title: String, _ items: [StandupItem]) -> String {
            "*\(title)*\n" + (items.isEmpty ? "• nothing\n" : items.map { "• " + ($0.ticket.flatMap { $0.isEmpty ? nil : "\($0) — " } ?? "") + (StandupItem.label($0.kind).map { "\($0): " } ?? "") + $0.text + ($0.refs.isEmpty ? "" : " (\($0.refs.joined(separator: ", ")))") + "\n" }.joined())
        }
        return section("Yesterday I did", yesterday) + section("Today I will", today) + section("Blockers", blockers)
    }
}

struct MeetingReport: Codable, Hashable, Sendable {
    struct Person: Codable, Hashable, Sendable {
        var name: String
        var yesterday: [String]
        var today: [String]
        var blockers: [String]
        /// Lines or words spoken (from Zoom's captions).
        var words: Int?
    }

    struct Action: Codable, Hashable, Sendable {
        var owner: String
        var task: String
    }

    var summary: String
    var people: [Person]
    var blockers: [Action]
    var actionItems: [Action]
    /// Participants who didn't speak.
    var notHeard: [String]
    /// Whether names come from Zoom's captions (else Claude attributed lines from context).
    var namesFromCaptions: Bool
}

enum StandupDayKey {
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of the previous working day (Friday for a Monday), among `workdays` (1 = Sunday).
    static func previousWorkday(before date: Date, workdays: Set<Int>, calendar: Calendar = .current) -> Date {
        var day = calendar.startOfDay(for: date)
        for _ in 0..<7 {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
            if workdays.contains(calendar.component(.weekday, from: day)) { return day }
        }
        return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date))!
    }
}
