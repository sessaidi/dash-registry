import DashKit
import Foundation
import SwiftData

/// Agent sessions for DashQL: the `agents` dataset and the Agents widget's query bar.
extension AgentSession {
    static let queryFields: [QueryDataset.Field] = [
        .init("id", "string", "Session id"),
        .init("issue_key", "string", "The Jira ticket (joins jira.key and prs.tickets)", aliases: ["ticket", "key"]),
        .init("title", "string", "Ticket title"),
        .init("phase", "string", "planning or implementing"),
        .init("status", "string", "idle, running or failed"),
        .init("branch", "string", "Its git branch"),
        .init("base", "string", "What it branched from"),
        .init("repo", "string", "Repository path"),
        .init("worktree", "string", "Worktree path"),
        .init("cost_usd", "number", "Claude cost so far", aliases: ["cost"]),
        .init("has_pr", "bool", "A PR was opened"),
        .init("pr_url", "string", "Its PR"),
        .init("error", "string", "The last error"),
        .init("created", "date", "Started"),
        .init("updated", "date", "Last activity"),
    ]

    var queryRow: JSONValue {
        [
            "id": .string(id.uuidString), "issue_key": .string(issueKey), "title": .string(title), "phase": .string(phase),
            "status": .string(status), "branch": .string(branch), "base": .string(baseRef), "repo": .string(repoPath),
            "worktree": .string(worktreePath), "cost_usd": .number(costUSD), "has_pr": .bool(prURL != nil),
            "pr_url": prURL.queryValue, "error": lastError.queryValue, "created": createdAt.queryValue, "updated": updatedAt.queryValue,
        ]
    }
}

extension AgentsExtension {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "agents", summary: "Claude Code agent sessions on Jira tickets (newest first).",
                      fields: AgentSession.queryFields) { [weak self] _ in
            guard let context = self?.host?.context else { return [] }
            return ((try? context.fetch(FetchDescriptor<AgentSession>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []).map(\.queryRow)
        }]
    }
}
