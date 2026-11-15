import DashKit
import Foundation
import SwiftData

/// Agent sessions for Dash's knowledge graph: the ticket each works on and the PR it opened.
extension AgentsExtension {
    var knowledge: [KnowledgeEntity] {
        guard let context = host?.context else { return [] }
        return ((try? context.fetch(FetchDescriptor<AgentSession>())) ?? []).map { session in
            var links = [KnowledgeLink(to: "ticket:\(session.issueKey)", kind: "works_on")]
            // "https://github.com/owner/name/pull/12" → "pr:owner/name#12"
            if let url = session.prURL.flatMap(URL.init(string:)), url.pathComponents.count >= 5, url.pathComponents[3] == "pull" {
                links.append(KnowledgeLink(to: "pr:\(url.pathComponents[1])/\(url.pathComponents[2])#\(url.pathComponents[4])", kind: "opened"))
            }
            return KnowledgeEntity(
                id: "agent:\(session.id.uuidString)", kind: "agent", title: "Agent on \(session.issueKey): \(session.title)",
                text: "Phase \(session.phase), \(session.status). Branch \(session.branch) from \(session.baseRef) in \(session.repoPath)."
                    + (session.lastError.map { " Last error: \($0)" } ?? ""),
                url: session.prURL.flatMap(URL.init(string:)), updated: session.updatedAt, links: links)
        }
    }

    /// Worktrees (agent sessions) started per day.
    var activitySeries: [ActivitySeries] {
        [ActivitySeries(id: "worktrees", title: "Worktrees created", unit: "worktrees", systemImage: "arrow.triangle.branch") { [weak self] interval in
            let sessions = (try? self?.host?.context.fetch(FetchDescriptor<AgentSession>())) ?? []
            return ActivitySeries.countPerDay(sessions.map(\.createdAt), in: interval)
        }]
    }
}
