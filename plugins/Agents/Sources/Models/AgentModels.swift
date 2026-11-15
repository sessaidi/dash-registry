import DashKit
import DashKitUI
import Foundation
import SwiftData

@Model
final class AgentSession {
    @Attribute(.unique) var id: UUID
    var issueKey: String
    var title: String
    var repoPath: String
    var worktreePath: String
    var branch: String
    var baseRef: String
    var claudeSessionID: String?
    /// planning: discussing the approach (read-only). implementing: TDD loop with edits allowed.
    var phase: String
    /// idle, running, failed
    var status: String
    var lastError: String?
    var costUSD: Double
    var prURL: String?
    var createdAt: Date
    var updatedAt: Date
    var nextSequence: Int

    init(issueKey: String, title: String, repoPath: String, worktreePath: String, branch: String, baseRef: String) {
        id = UUID()
        self.issueKey = issueKey
        self.title = title
        self.repoPath = repoPath
        self.worktreePath = worktreePath
        self.branch = branch
        self.baseRef = baseRef
        phase = "planning"
        status = "idle"
        costUSD = 0
        createdAt = .now
        updatedAt = .now
        nextSequence = 0
    }

    var json: JSONValue {
        ["id": .string(id.uuidString), "issue": .string(issueKey), "title": .string(title), "branch": .string(branch),
         "worktree": .string(worktreePath), "phase": .string(phase), "status": .string(status),
         "cost_usd": .number(costUSD), "pr_url": prURL.map(JSONValue.string) ?? .null, "error": lastError.map(JSONValue.string) ?? .null]
    }
}

@Model
final class AgentMessage {
    var id: UUID
    var sessionID: UUID
    var sequence: Int
    /// user, assistant, tool, error, info
    var role: String
    var text: String
    var createdAt: Date

    init(sessionID: UUID, sequence: Int, role: String, text: String) {
        id = UUID()
        self.sessionID = sessionID
        self.sequence = sequence
        self.role = role
        self.text = text
        createdAt = .now
    }
}

/// What a widget row shows about a session; decoupled from SwiftData so previews can use samples.
struct AgentSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let issueKey: String
    let title: String
    let phase: String
    let branch: String
    let status: String
    let costUSD: Double
    let hasPullRequest: Bool

    init(id: UUID = UUID(), issueKey: String, title: String, phase: String, branch: String, status: String, costUSD: Double, hasPullRequest: Bool) {
        self.id = id
        self.issueKey = issueKey
        self.title = title
        self.phase = phase
        self.branch = branch
        self.status = status
        self.costUSD = costUSD
        self.hasPullRequest = hasPullRequest
    }

    init(_ session: AgentSession) {
        self.init(id: session.id, issueKey: session.issueKey, title: session.title, phase: session.phase, branch: session.branch,
                  status: session.status, costUSD: session.costUSD, hasPullRequest: session.prURL != nil)
    }

    /// Sessions with a PR are "finished"; the widget can hide them.
    static func visible(_ rows: [AgentSummary], showFinished: Bool) -> [AgentSummary] {
        rows.filter { showFinished || !$0.hasPullRequest }
    }

    /// Gallery and Settings sample: no store, no processes.
    static let samples: [AgentSummary] = [
        AgentSummary(issueKey: "LAF-1234", title: "Add retry to the fetcher", phase: "implementing",
                     branch: "laf-1234-add-retry-to-the-fetcher", status: "running", costUSD: 1.42, hasPullRequest: false),
        AgentSummary(issueKey: "LAF-1198", title: "Cache channel lineups per market", phase: "planning",
                     branch: "laf-1198-cache-channel-lineups-per-market", status: "idle", costUSD: 0.31, hasPullRequest: false),
        AgentSummary(issueKey: "OPS-77", title: "Fix flaky deploy health check", phase: "implementing",
                     branch: "ops-77-fix-flaky-deploy-health-check", status: "idle", costUSD: 2.08, hasPullRequest: true),
        AgentSummary(issueKey: "LAF-1240", title: "Drop the legacy auth header", phase: "planning",
                     branch: "laf-1240-drop-the-legacy-auth-header", status: "failed", costUSD: 0.05, hasPullRequest: false),
    ]
}

/// A repository's own pull request template; repositories without one use the global template
/// (Agents › AI › Opening pull requests). Placeholders: {{issue_key}}, {{issue_title}},
/// {{ticket_url}}, {{summary}}, {{branch}}, {{base}}.
@Model
final class PullRequestTemplate {
    @Attribute(.unique) var repoPath: String
    var title: String
    var body: String

    init(repoPath: String, title: String, body: String) {
        self.repoPath = repoPath
        self.title = title
        self.body = body
    }
}

/// A PR the user is reviewing before it's opened.
struct PullRequestDraft: Equatable {
    var title: String
    var body: String
    var base: String
    var branch: String
    /// Whether the repository's own template was used instead of the global one.
    var repoTemplate: Bool
}
