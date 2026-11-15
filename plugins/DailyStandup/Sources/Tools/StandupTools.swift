import DashKit
import Foundation

/// Dashii tools: today's standup, prepare, blockers, history.
extension DailyStandupFeature {
    private struct DayInput: Decodable { let date: String? }

    var tools: [DashiiTool] {
        [
            DashiiTool(name: "standup_today", description: "Today's standup: my update (yesterday, today, blockers with references), and on Zoom days the meeting report (each person's update, blockers, action items).") { [weak self] _ in
                guard let self, let record = day() else { return ["prepared": false] }
                return ["prepared": .bool(record.preparedAt != nil), "update": .string(record.update?.text ?? ""),
                        "report": (try? JSONValue(encoding: record.report)) ?? .null, "on_zoom": .bool(record.onZoom)]
            },
            DashiiTool(name: "standup_prepare", description: "Prepare (or redo) my standup update now from my commits, PRs, tickets, agents, deploys, notes and meetings since the last standup.") { [weak self] _ in
                guard let self else { return nil }
                return .string(try await prepare().text)
            },
            DashiiTool(name: "standup_blockers", description: "Open blockers from past standups (mine and the team's), with how long they've been open.") { [weak self] _ in
                guard let self else { return [] }
                return .array(openBlockers().map { ["text": .string($0.text), "owner": .string($0.owner), "days_open": .number(Double($0.daysOpen)), "reference": .string($0.reference)] })
            },
            DashiiTool(name: "standup_history", description: "Past standups (date, my update, meeting summary).",
                       properties: ["date": JSONSchema.string("Optional yyyy-MM-dd.")]) { [weak self] input in
                guard let self else { return [] }
                let wanted = try input.toolInput(DayInput.self).date
                return .array(days().filter { wanted == nil || $0.day == wanted }.map {
                    ["date": .string($0.day), "update": .string($0.update?.text ?? ""), "summary": .string($0.report?.summary ?? "")]
                })
            },
        ]
    }
}
