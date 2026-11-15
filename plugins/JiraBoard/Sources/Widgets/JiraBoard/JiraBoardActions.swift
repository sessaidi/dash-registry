import DashKit
import Foundation

/// What Dashii can do with the Jira board widget. Only what it shows changes, and only for now:
/// the widget's saved settings and Jira itself are untouched.
enum JiraBoardActions {
    static let actions = [
        WidgetAction(name: "search", description: "Narrow the board to issues whose key, summary, assignee or status contains the text. Empty clears it.",
                     properties: ["text": JSONSchema.string("Search text.")], required: ["text"]),
        WidgetAction(name: "filter_status", description: "Only one column or status (e.g. In Progress, Code Review); empty shows every column.",
                     properties: ["status": JSONSchema.string("Column or status name.")], required: ["status"]),
        WidgetAction(name: "set_mode", description: "Show the board's columns, or the issues the user follows. Temporary: the widget's saved setting stays.",
                     properties: ["mode": JSONSchema.string("board or followed.", enum: ["board", "followed"])], required: ["mode"]),
        WidgetAction(name: "set_board", description: "Show another followed board, by name or id. Temporary: the widget's saved board stays.",
                     properties: ["board": JSONSchema.string("Board name or id.")], required: ["board"]),
        WidgetAction(name: "hide_done", description: "Hide (on) or show (off) finished issues. Temporary: the widget's saved setting stays.",
                     properties: ["on": JSONSchema.boolean("true to hide done issues.")], required: ["on"]),
        WidgetAction(name: "select_issue", description: "Select an issue by key and open its detail; linked widgets follow the selection.",
                     properties: ["key": JSONSchema.string("Issue key, e.g. LAF-1234.")], required: ["key"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected issue."),
        WidgetAction(name: "clear", description: "Clear the search, status filter and Dashii's temporary mode, board and hide-done (back to the widget's settings)."),
    ]

    struct Outcome {
        var reply: JSONValue
        var select: JiraTicket?
    }

    /// The tickets matching a search and a column (by name) or status name.
    static func filter(_ tickets: [JiraTicket], search: String, status: String, columns: [JiraClient.Column]) -> [JiraTicket] {
        let text = search.trimmingCharacters(in: .whitespaces).lowercased()
        let wanted = status.trimmingCharacters(in: .whitespaces).lowercased()
        let column = columns.first { $0.name.lowercased() == wanted }
        return tickets.filter { ticket in
            (text.isEmpty || [ticket.key, ticket.summary, ticket.assignee ?? "", ticket.statusName].contains { $0.lowercased().contains(text) })
                && (wanted.isEmpty || column.map { $0.statusIDs.contains(ticket.statusID) } ?? (ticket.statusName.lowercased() == wanted))
        }
    }

    static func perform(_ name: String, _ input: JSONValue, config: inout JiraBoardWidget.Config, search: inout String, status: inout String,
                        tickets: [JiraTicket], boards: [(id: Int, name: String)], columns: [JiraClient.Column]) throws -> Outcome {
        switch name {
        case "search":
            search = input["text"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            return Outcome(reply: ["search": search.isEmpty ? .null : .string(search)])
        case "filter_status":
            let wanted = input["status"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            let known = columns.map(\.name) + tickets.map(\.statusName)
            if !wanted.isEmpty, !known.contains(where: { $0.lowercased() == wanted.lowercased() }) {
                throw ToolError("No column or status “\(wanted)”. Columns: \(columns.map(\.name).joined(separator: ", ")).")
            }
            status = wanted
            return Outcome(reply: ["status": wanted.isEmpty ? .null : .string(wanted)])
        case "set_mode":
            guard let mode = input["mode"]?.string, ["board", "followed"].contains(mode) else { throw ToolError("Mode is board or followed.") }
            config.mode = mode
            return Outcome(reply: ["mode": .string(mode)])
        case "set_board":
            let wanted = input["board"]?.string ?? input["board"]?.int.map(String.init) ?? ""
            guard let board = boards.first(where: { String($0.id) == wanted || $0.name.lowercased() == wanted.lowercased() })
                    ?? boards.first(where: { $0.name.lowercased().contains(wanted.lowercased()) }), !wanted.isEmpty else {
                throw ToolError("No followed board “\(wanted)”. Boards: \(boards.map(\.name).joined(separator: ", ")).")
            }
            config.mode = "board"
            config.board = board.id
            return Outcome(reply: ["board": .string(board.name)])
        case "hide_done":
            config.hideDone = input["on"]?.bool ?? true
            return Outcome(reply: ["hide_done": .bool(config.hideDone)])
        case "select_issue":
            let key = input["key"]?.string?.uppercased() ?? ""
            guard let ticket = tickets.first(where: { $0.key == key }) else { throw ToolError("\(key) isn't on this widget.") }
            return Outcome(reply: ["opened": .string(ticket.key)], select: ticket)
        case "clear":
            search = ""
            status = ""
            return Outcome(reply: "cleared")
        default:
            throw ToolError("Unknown action \(name).")
        }
    }
}
