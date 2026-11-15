import DashKit
import Foundation
import SwiftData

/// Meetings for DashQL: the `meetings` dataset and the Meeting widget's query bar (past meetings).
extension MeetingRecord {
    static let queryFields: [QueryDataset.Field] = [
        .init("id", "string", "Meeting id"),
        .init("title", "string", "Meeting title"),
        .init("started", "date", "When it started", aliases: ["date"]),
        .init("ended", "date", "When it ended"),
        .init("minutes", "number", "Duration in minutes", aliases: ["duration"]),
        .init("participants", "list", "Everyone seen in the participant list", aliases: ["people"]),
        .init("summary", "string", "Dashii's summary"),
        .init("decisions", "list", "Decisions"),
        .init("action_items", "list", "Action items as owner: task", aliases: ["actions"]),
        .init("owners", "list", "Who has action items"),
        .init("tickets", "list", "Ticket keys mentioned in the summary, decisions and action items (joins jira.key)"),
        .init("recorded", "bool", "Audio or video was saved"),
    ]

    var queryRow: JSONValue {
        let items = actionItems
        let text = ([summary] + decisions + items.map(\.task)).joined(separator: "\n").uppercased()
        let tickets = Array(Set(text.matches(of: /[A-Z][A-Z0-9]{1,9}-\d+/).map { String($0.output) })).sorted()
        return [
            "id": .string(id.uuidString), "title": .string(title), "started": startedAt.queryValue, "ended": endedAt.queryValue,
            "minutes": endedAt.map { .number(($0.timeIntervalSince(startedAt) / 60).rounded()) } ?? .null,
            "participants": .array(participants.map(JSONValue.string)), "summary": .string(summary),
            "decisions": .array(decisions.map(JSONValue.string)),
            "action_items": .array(items.map { .string("\($0.owner): \($0.task)") }),
            "owners": .array(Array(Set(items.map(\.owner))).sorted().map(JSONValue.string)),
            "tickets": .array(tickets.map(JSONValue.string)), "recorded": .bool(recordingPath != nil),
        ]
    }
}

extension ZoomExtension {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "meetings", aliases: ["calls"], summary: "Zoom meetings Dash transcribed, with summary, decisions and action items (newest first).",
                      fields: MeetingRecord.queryFields) { [weak self] _ in
            guard let context = self?.host?.context else { return [] }
            return ((try? context.fetch(FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []).map(\.queryRow)
        }]
    }
}
