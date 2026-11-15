import DashKit
import Foundation
import Testing

/// Agent sessions in DashQL: the `agents` dataset and the widget's query.
@MainActor
struct AgentsQueryTests {
    @Test func datasetAndWidgetQuery() async throws {
        let (agents, host) = makeAgents()
        let planning = AgentSession(issueKey: "LAF-1", title: "Crash", repoPath: "/r", worktreePath: "/w1", branch: "LAF-1-crash", baseRef: "origin/main")
        let done = AgentSession(issueKey: "LAF-2", title: "Docs", repoPath: "/r", worktreePath: "/w2", branch: "LAF-2-docs", baseRef: "origin/main")
        done.prURL = "https://github.com/acme/api/pull/9"
        done.costUSD = 2.5
        host.context.insert(planning)
        host.context.insert(done)
        try host.context.save()

        let rows = try await #require(agents.datasets.first { $0.name == "agents" }).rows(nil)
        #expect(Set(rows.compactMap { $0["issue_key"]?.string }) == ["LAF-1", "LAF-2"])
        let withPR = try await QueryEngine(datasets: agents.datasets).run("agents has_pr=true | select ticket, cost")
        #expect(withPR.rows == [["ticket": "LAF-2", "cost": 2.5]])

        let query = try #require(try WidgetQuery("ticket:LAF-1", fields: AgentsWidget.queryFields))
        #expect(await query.apply(to: [planning, done], row: \.queryRow).map(\.issueKey) == ["LAF-1"])
    }
}
