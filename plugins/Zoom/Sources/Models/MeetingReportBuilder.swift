import DashKit
import Foundation

/// The meeting report, written in Dash's note syntax from Dashii's structured answer: a summary
/// callout, each person's update as a table, topics, decisions, risks as warnings, and action items
/// as a task list. Stored on the meeting (`MeetingRecord.report`), rendered in its sheet, saved as a
/// note on request.
enum MeetingReportBuilder {
    static let schema: JSONValue = [
        "type": "object", "additionalProperties": false,
        "required": ["title", "summary", "people", "topics", "decisions", "risks", "action_items", "speakers"],
        "properties": [
            "title": ["type": "string", "description": "Short meeting title from its content."],
            "summary": ["type": "string", "description": "Two or three sentences: what the meeting was and what came out of it."],
            "people": [
                "type": "array", "description": "One entry per person who gave an update (standups) or spoke substantively.",
                "items": ["type": "object", "additionalProperties": false, "required": ["name", "done", "next", "blockers"],
                          "properties": ["name": ["type": "string"], "done": ["type": "string", "description": "What they did or reported, short."],
                                         "next": ["type": "string", "description": "What they'll do next, short; empty if not said."],
                                         "blockers": ["type": "string", "description": "What blocks them; empty if nothing."]]],
            ],
            "topics": [
                "type": "array", "description": "The subjects discussed beyond the round of updates, each with its key points.",
                "items": ["type": "object", "additionalProperties": false, "required": ["title", "points"],
                          "properties": ["title": ["type": "string"], "points": ["type": "array", "items": ["type": "string"]]]],
            ],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "risks": ["type": "array", "description": "Things that could slip or go wrong (a merge on hold, a big conflict, an unreproduced bug).", "items": ["type": "string"]],
            "action_items": [
                "type": "array",
                "items": ["type": "object", "additionalProperties": false, "required": ["owner", "task"],
                          "properties": ["owner": ["type": "string"], "task": ["type": "string"]]],
            ],
            "speakers": [
                "type": "array",
                "description": "For transcript lines marked Others (by their [n] number): who most likely said it, only when the content makes it clear (a name addressed, a self-introduction, an update matching a person). Leave a line out when unsure.",
                "items": ["type": "object", "additionalProperties": false, "required": ["line", "name"],
                          "properties": ["line": ["type": "integer"], "name": ["type": "string"]]],
            ],
        ],
    ]

    /// Markdown in Dash's note syntax.
    static func markdown(_ result: JSONValue, meeting: MeetingRecord) -> String {
        var lines: [String] = []
        let when = meeting.startedAt.formatted(date: .abbreviated, time: .shortened)
        let minutes = meeting.endedAt.map { Int(($0.timeIntervalSince(meeting.startedAt) / 60).rounded()) }
        lines.append("> [!summary] \(when)\(minutes.map { " · \($0) min" } ?? "")\(meeting.participants.isEmpty ? "" : " · \(meeting.participants.count) people")")
        lines.append("> " + (result["summary"]?.string ?? ""))
        func cell(_ text: String?) -> String {
            let value = (text ?? "").replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
            return value.isEmpty ? "—" : value
        }
        let people = result["people"]?.array ?? []
        if !people.isEmpty {
            lines += ["", "## Updates", "", "| Who | Done | Next | Blockers |", "|---|---|---|---|"]
            for person in people {
                lines.append("| **\(cell(person["name"]?.string))** | \(cell(person["done"]?.string)) | \(cell(person["next"]?.string)) | \(cell(person["blockers"]?.string)) |")
            }
        }
        for topic in result["topics"]?.array ?? [] {
            guard let title = topic["title"]?.string else { continue }
            lines += ["", "### \(title)"]
            lines += (topic["points"]?.array ?? []).compactMap(\.string).map { "- \($0)" }
        }
        let decisions = (result["decisions"]?.array ?? []).compactMap(\.string)
        if !decisions.isEmpty { lines += ["", "## Decisions"] + decisions.map { "- \($0)" } }
        for risk in (result["risks"]?.array ?? []).compactMap(\.string) {
            lines += ["", "> [!warning] Risk", "> \(risk)"]
        }
        let actions = result["action_items"]?.array ?? []
        if !actions.isEmpty {
            lines += ["", "## Action items"]
            lines += actions.map { "- [ ] **\($0["owner"]?.string ?? "?")**: \($0["task"]?.string ?? "")" }
        }
        return lines.joined(separator: "\n")
    }
}
