import DashKit
import Foundation
import SwiftData
import Testing

@MainActor
struct AgentSuggestionTests {
    @Test func failedPlanningAndReadySessions() throws {
        let (agents, host) = makeAgents()
        func session(_ key: String, status: String, phase: String, pr: String? = nil) {
            let session = AgentSession(issueKey: key, title: key, repoPath: "/r", worktreePath: "/w/\(key)", branch: key, baseRef: "origin/main")
            session.status = status
            session.phase = phase
            session.prURL = pr
            host.context.insert(session)
        }
        session("A-1", status: "failed", phase: "implementing")
        session("A-2", status: "idle", phase: "planning")
        session("A-3", status: "idle", phase: "implementing")
        session("A-4", status: "idle", phase: "implementing", pr: "https://example.com/pr/4")
        session("A-5", status: "running", phase: "implementing")

        let titles = Set(agents.suggestions.map(\.title))
        #expect(titles == ["Agent on A-1 failed", "Plan for A-2 awaits your approval", "Agent on A-3 is waiting for you"])
        #expect(agents.events.map(\.kind) == ["agent.turn_finished", "agent.stopped", "agent.failed", "agent.pr_opened"])
    }
}
