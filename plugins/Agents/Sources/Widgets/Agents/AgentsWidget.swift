import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// Agents: Dashii agents working on Jira tickets, selectable for linked widgets.
struct AgentsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var showFinished: Bool
    }

    static let kind = "agents.sessions"
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let displayName = "Agents"
    static let summary = "Dashii agents working on Jira tickets in their own git worktrees. Open one to discuss the plan and follow its TDD progress."
    static let systemImage = "hammer"
    static let defaultConfig = Config(showFinished: true)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["showFinished": ["type": "boolean", "description": "Include sessions that already have a PR."]],
    ]

    static let queryFields = AgentSession.queryFields
    static let actions = [
        WidgetAction(name: "select", description: "Select an agent session by ticket key (or id); linked widgets follow the selection. Temporary.",
                     properties: ["key": JSONSchema.string("Ticket key, e.g. LAF-1234, or the session id.")], required: ["key"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected session."),
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        AgentList(showFinished: config.wrappedValue.showFinished, host: context.host,
                  query: context.query(fields: AgentSession.queryFields), queryText: context.queryText)
    }

    static func preview(config: Config) -> some View {
        AgentsLayout(rows: AgentSummary.visible(AgentSummary.samples, showFinished: config.showFinished), open: { _ in })
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let sessions = (try? context.host.context.fetch(FetchDescriptor<AgentSession>())) ?? []
        return .array(sessions.filter { config.showFinished || $0.prURL == nil }.map(\.json))
    }
}
