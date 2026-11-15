import DashKit
import Foundation
import SwiftData

/// Standups for DashQL: the `standups` dataset (each day's update and meeting report) and the
/// `blockers` one (carried from day to day until resolved).
extension StandupDay {
    var queryRow: JSONValue {
        let update = update
        let report = report
        func items(_ list: [StandupItem]?) -> JSONValue { .array((list ?? []).map { .string(($0.ticket.map { "\($0) — " } ?? "") + $0.text) }) }
        let tickets = Set(([update?.yesterday, update?.today, update?.blockers].compactMap { $0 }.flatMap { $0 }).compactMap(\.ticket).filter { !$0.isEmpty })
        return [
            "day": .string(day), "date": date.queryValue, "on_zoom": .bool(onZoom), "prepared": preparedAt.queryValue,
            "yesterday": items(update?.yesterday), "today": items(update?.today), "my_blockers": items(update?.blockers),
            "tickets": .array(tickets.sorted().map(JSONValue.string)),
            "summary": report.map { .string($0.summary) } ?? .null,
            "people": .array((report?.people ?? []).map { .string($0.name) }),
            "action_items": .array((report?.actionItems ?? []).map { .string("\($0.owner): \($0.task)") }),
            "not_heard": .array((report?.notHeard ?? []).map(JSONValue.string)),
            "reported": reportedAt.queryValue, "note": notePath.isEmpty ? .null : .string(notePath),
        ]
    }

    static let queryFields: [QueryDataset.Field] = [
        .init("day", "string", "YYYY-MM-DD"), .init("date", "date", "The day"), .init("on_zoom", "bool", "The daily was on Zoom"),
        .init("prepared", "date", "When the update was prepared"),
        .init("yesterday", "list", "What the user did"), .init("today", "list", "What the user will do"),
        .init("my_blockers", "list", "The user's blockers"), .init("tickets", "list", "Tickets in the update (joins jira.key)"),
        .init("summary", "string", "Meeting summary"), .init("people", "list", "Who spoke"),
        .init("action_items", "list", "Action items as owner: task"), .init("not_heard", "list", "Participants who didn't speak"),
        .init("reported", "date", "When the meeting was reported"), .init("note", "string", "The note it was saved to"),
    ]
}

extension StandupBlocker {
    var queryRow: JSONValue {
        [
            "id": .string(id.uuidString), "text": .string(text), "owner": .string(owner),
            "reference": reference.isEmpty ? .null : .string(reference), "since": since.queryValue,
            "last_mentioned": lastMentioned.queryValue, "resolved": resolvedAt.queryValue, "open": .bool(resolvedAt == nil),
            "days_open": .number(((resolvedAt ?? .now).timeIntervalSince(since) / 86_400).rounded()),
        ]
    }

    static let queryFields: [QueryDataset.Field] = [
        .init("id"), .init("text", "string", "The blocker"), .init("owner", "string", "Who it blocks"),
        .init("reference", "string", "Ticket key, PR or workspace it's about", aliases: ["ticket"]),
        .init("since", "date", "First mentioned"), .init("last_mentioned", "date", "Last mentioned"),
        .init("resolved", "date", "When it was resolved"), .init("open", "bool", "Not resolved yet"),
        .init("days_open", "number", "Days it has been open (or was)"),
    ]
}

extension DailyStandupFeature {
    var datasets: [QueryDataset] {
        [
            QueryDataset(name: "standups", summary: "Daily standups: the user's prepared update and the meeting report, per day (newest first).",
                         fields: StandupDay.queryFields) { [weak self] _ in
                guard let context = self?.host?.context else { return [] }
                return ((try? context.fetch(FetchDescriptor<StandupDay>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []).map(\.queryRow)
            },
            QueryDataset(name: "blockers", summary: "Blockers raised in standups, carried until resolved.", fields: StandupBlocker.queryFields) { [weak self] _ in
                guard let context = self?.host?.context else { return [] }
                return ((try? context.fetch(FetchDescriptor<StandupBlocker>(sortBy: [SortDescriptor(\.since, order: .reverse)]))) ?? []).map(\.queryRow)
            },
        ]
    }
}
