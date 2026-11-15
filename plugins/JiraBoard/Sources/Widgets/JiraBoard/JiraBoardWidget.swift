import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// Jira Board: the issues you follow, in a board's columns or one column per status.
struct JiraBoardWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// Both show the issues you follow: "board" in the board's columns, "followed" by status.
        var mode: String
        var hideDone: Bool
        /// Which followed board ("board" mode); nil is the first one.
        var board: Int?
    }

    static let kind = "jira.board"
    static let sizeLimits = GridLimits(minW: 4, minH: 6, maxW: 12, maxH: 24)
    static let displayName = "Jira Board"
    static let summary = "The Jira issues you follow, in your board's columns or by status. Open a ticket to comment, move it, or start an agent on it."
    static let systemImage = "checklist"
    static let defaultSize = WidgetSize.wide
    static let defaultConfig = Config(mode: "followed", hideDone: false)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "mode": ["type": "string", "enum": ["board", "followed"], "description": "Both show only the issues the user follows. board: in the configured board's columns. followed: one column per status."],
            "hideDone": ["type": "boolean", "description": "Hide issues in a Done status category."],
            "board": ["type": "integer", "description": "Board id (one of the followed boards); omit for the first."],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        JiraBoardView(config: config, host: context.host, query: context.query(fields: JiraIssue.queryFields), queryText: context.queryText)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Picker("Show", selection: config.mode) {
            Text("In board columns").tag("board")
            Text("By status").tag("followed")
        }
        if config.wrappedValue.mode == "board", let jira = context.host.ext(JiraBoardFeature.self), jira.boards.count > 1 {
            Picker("Board", selection: config.board) {
                ForEach(jira.boards) { Text($0.name).tag(Optional($0.id)) }
            }
        }
        Toggle("Hide done", isOn: config.hideDone)
    }

    /// Sample tickets on a four-column board, in the same responsive view as the widget; no store,
    /// network or account.
    static func preview(config: Config) -> some View {
        JiraBoardContent(
            config: config, tickets: JiraTicket.visible(JiraTicket.samples, config: config),
            columns: JiraClient.Column.samples, onSelect: nil)
    }

    static let actions = JiraBoardActions.actions
    static let queryFields = JiraIssue.queryFields

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let issues = (try? context.host.context.fetch(FetchDescriptor<JiraIssue>())) ?? []
        var config = config
        let jira = context.host.ext(JiraBoardFeature.self)
        if config.board == nil { config.board = jira?.boards.first?.id }
        let tickets = JiraTicket.visible(issues.map(JiraTicket.init), config: config)
        let keys = Set(tickets.map(\.key))
        return [
            "explanation": """
                Jira issues the user follows, from Dash's local copy. mode board: grouped in a followed board's \
                columns (each column holds one or more statuses); mode followed: one column per status. status is the \
                issue's Jira status; status_category new = not started, indeterminate = in progress, done = finished.
                """,
            "mode": .string(config.mode),
            "board": jira?.boards.first { $0.id == config.board }.map { .string($0.name) } ?? .null,
            // The columns the widget draws, so every issue shown is in one.
            "columns": .array(JiraBoardLayout.columns(board: config.mode == "board" ? jira?.columns(board: config.board) ?? [] : [], tickets: tickets).map { column in
                ["name": .string(column.name), "issues": .number(Double(tickets.filter { column.statusIDs.contains($0.statusID) }.count))]
            }),
            "issues": .array(issues.filter { keys.contains($0.key) }.map(\.json)),
        ]
    }
}
