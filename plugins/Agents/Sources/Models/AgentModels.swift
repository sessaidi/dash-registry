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
    let updatedAt: Date
    let lastError: String?

    init(id: UUID = UUID(), issueKey: String, title: String, phase: String, branch: String, status: String, costUSD: Double, hasPullRequest: Bool,
         updatedAt: Date = .now, lastError: String? = nil) {
        self.id = id
        self.issueKey = issueKey
        self.title = title
        self.phase = phase
        self.branch = branch
        self.status = status
        self.costUSD = costUSD
        self.hasPullRequest = hasPullRequest
        self.updatedAt = updatedAt
        self.lastError = lastError
    }

    init(_ session: AgentSession) {
        self.init(id: session.id, issueKey: session.issueKey, title: session.title, phase: session.phase, branch: session.branch,
                  status: session.status, costUSD: session.costUSD, hasPullRequest: session.prURL != nil,
                  updatedAt: session.updatedAt, lastError: session.lastError)
    }

    /// Sessions with a PR are "finished"; the widget can hide them.
    static func visible(_ rows: [AgentSummary], showFinished: Bool) -> [AgentSummary] {
        rows.filter { showFinished || !$0.hasPullRequest }
    }

    /// Gallery and Settings sample: no store, no processes. Enough rows, states and ages that every
    /// size family looks like a real day.
    static let samples: [AgentSummary] = [
        AgentSummary(issueKey: "LAF-1234", title: "Add retry to the fetcher", phase: "implementing",
                     branch: "laf-1234-add-retry-to-the-fetcher", status: "running", costUSD: 1.42, hasPullRequest: false,
                     updatedAt: .now.addingTimeInterval(-40)),
        AgentSummary(issueKey: "LAF-1198", title: "Cache channel lineups per market", phase: "planning",
                     branch: "laf-1198-cache-channel-lineups-per-market", status: "idle", costUSD: 0.31, hasPullRequest: false,
                     updatedAt: .now.addingTimeInterval(-6 * 60)),
        AgentSummary(issueKey: "LAF-1251", title: "Paginate the recordings endpoint", phase: "implementing",
                     branch: "laf-1251-paginate-the-recordings-endpoint", status: "running", costUSD: 0.87, hasPullRequest: false,
                     updatedAt: .now.addingTimeInterval(-2 * 60)),
        AgentSummary(issueKey: "LAF-1240", title: "Drop the legacy auth header", phase: "planning",
                     branch: "laf-1240-drop-the-legacy-auth-header", status: "failed", costUSD: 0.05, hasPullRequest: false,
                     updatedAt: .now.addingTimeInterval(-25 * 60), lastError: "No repository for project LAF in this worktree."),
        AgentSummary(issueKey: "OPS-77", title: "Fix flaky deploy health check", phase: "implementing",
                     branch: "ops-77-fix-flaky-deploy-health-check", status: "idle", costUSD: 2.08, hasPullRequest: true,
                     updatedAt: .now.addingTimeInterval(-3 * 3600)),
        AgentSummary(issueKey: "WEB-412", title: "Show the plan price on checkout", phase: "implementing",
                     branch: "web-412-show-the-plan-price-on-checkout", status: "idle", costUSD: 1.16, hasPullRequest: true,
                     updatedAt: .now.addingTimeInterval(-26 * 3600)),
    ]
}

extension AgentSummary {
    /// The agent is taking a turn right now.
    var isWorking: Bool { status == "running" }
    /// Waiting on the user: it failed, or it's idle without a PR (a plan to discuss, a step to approve).
    var needsYou: Bool { !isWorking && !hasPullRequest }
    /// Its PR is open: the agent is done.
    var isDone: Bool { !isWorking && hasPullRequest }

    var tone: Tone { isWorking ? .info : status == "failed" ? .danger : hasPullRequest ? .success : .warning }
    var stateLabel: String { isWorking ? "Working" : status == "failed" ? "Failed" : hasPullRequest ? "PR open" : "Needs you" }

    /// "2 working · 1 needs you", what a glance should say.
    static func headline(_ rows: [AgentSummary]) -> String {
        let working = rows.count(where: \.isWorking), waiting = rows.count(where: \.needsYou), done = rows.count(where: \.isDone)
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if waiting > 0 { parts.append("\(waiting) need\(waiting == 1 ? "s" : "") you") }
        if parts.isEmpty, done > 0 { parts.append("\(done) done") }
        return parts.isEmpty ? "No agents" : parts.joined(separator: " · ")
    }

    /// What to look at first: failed, then waiting on you, then working, then done; newest first in each.
    static func byAttention(_ rows: [AgentSummary]) -> [AgentSummary] {
        func rank(_ row: AgentSummary) -> Int { row.status == "failed" && !row.hasPullRequest ? 0 : row.needsYou ? 1 : row.isWorking ? 2 : 3 }
        return rows.sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.updatedAt > $1.updatedAt }
    }
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
