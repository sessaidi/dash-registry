import DashKit
import Foundation
import SwiftData

/// Home suggestions from the agent sessions already stored.
extension AgentsExtension {
    var suggestions: [Suggestion] {
        guard let context = host?.context else { return [] }
        let sessions = (try? context.fetch(FetchDescriptor<AgentSession>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        var result: [Suggestion] = []
        for session in sessions where session.prURL == nil {
            switch (session.status, session.phase) {
            case ("failed", _):
                result.append(Suggestion(
                    id: "agents.failed.\(session.id)", title: "Agent on \(session.issueKey) failed",
                    detail: session.lastError ?? session.title, icon: "exclamationmark.triangle", priority: .high,
                    prompt: "The agent on \(session.issueKey) failed. Read its last messages (agents_read) and tell me what went wrong and how to resume it."))
            case ("idle", "planning"):
                result.append(Suggestion(
                    id: "agents.plan.\(session.id)", title: "Plan for \(session.issueKey) awaits your approval",
                    detail: session.title, icon: "checklist", priority: .high,
                    prompt: "Show me the agent's plan for \(session.issueKey) so I can approve it or ask for changes."))
            case ("idle", "implementing"):
                result.append(Suggestion(
                    id: "agents.ready.\(session.id)", title: "Agent on \(session.issueKey) is waiting for you",
                    detail: "Review its work, then open a draft PR.", icon: "hammer", priority: .normal,
                    prompt: "Summarise what the agent did on \(session.issueKey) (branch \(session.branch)) and whether it's ready for a PR."))
            default:
                continue
            }
        }
        let cost = sessions.filter { $0.updatedAt > Date.now.addingTimeInterval(-7 * 86_400) }.map(\.costUSD).reduce(0, +)
        if cost >= 50 {
            result.append(Suggestion(
                id: "agents.cost", title: String(format: "Agents spent $%.0f this week", cost),
                icon: "dollarsign.circle", priority: .low,
                prompt: "Break down this week's agent spending by ticket and suggest where a cheaper model would do."))
        }
        return result
    }

    var events: [EventDefinition] {
        [EventDefinition("agent.turn_finished", "An agent finished a turn (planning or implementing)."),
         EventDefinition("agent.stopped", "An agent's turn ended with an error result, e.g. after Stop."),
         EventDefinition("agent.failed", "An agent's turn failed."),
         EventDefinition("agent.pr_opened", "An agent opened a draft PR.")]
    }
}
