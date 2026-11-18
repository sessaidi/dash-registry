import DashKit
import DashKitTesting
import Foundation
import SwiftData
import Testing

/// Dashii's agents_start and worktree_link use what's on the Mac and in Dash: the stored ticket,
/// an existing clone, the last fetched origin, stored pull requests. The user's start fetches.
@MainActor
@Suite(.serialized)
struct AgentsOfflineTests {
    func ticket(_ key: String) -> JSONValue {
        ["key": .string(key), "summary": "Retry failed renewals", "description": "Retry three times.", "synced_at": "2026-11-18T10:00:00Z", "stale": false]
    }

    @Test func dashiiAsksToFetchATicketDashDoesntHave() async throws {
        let atlassian = FakeReaders(id: "atlassian")
        atlassian.answers["jira_issue"] = notFetched("jira.issue", input: ["key": "KAN-12"])
        let (agents, host) = makeAgents([atlassian]) { $0.set("KAN=/tmp", forKey: "agents.repoMap") }
        let answer = try #require(try await agents.tools.first { $0.name == "agents_start" }?.run(["issue_key": "kan-12"]))
        #expect(answer["fetched"] == false && answer["refresh"] == ["fetcher": "jira.issue", "input": ["key": "KAN-12"]])
        #expect(answer["hint"]?.string?.contains("agents_start again") == true)
        #expect(atlassian.calls == ["jira_issue"])
        #expect(try host.context.fetch(FetchDescriptor<AgentSession>()).isEmpty)
    }

    @Test func dashiiDoesntCloneMissingRepositories() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agents-offline-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let atlassian = FakeReaders(id: "atlassian")
        atlassian.answers["jira_issue"] = ticket("KAN-12")
        let (agents, _) = makeAgents([atlassian]) {
            $0.set("KAN=acme/billing-api", forKey: "agents.repoMap")
            $0.set(root.path, forKey: "agents.codeRoot")
        }
        await #expect(throws: ToolError.self) { try await agents.tools.first { $0.name == "agents_start" }?.run(["issue_key": "KAN-12"]) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "billing-api").path))
        await #expect(throws: ToolError.self) { try await AgentsExtension.ensureClone("acme/billing-api", codeRoot: root.path, clone: false) }
    }

    @Test func storedTicketReadsAtlassiansReader() async throws {
        let atlassian = FakeReaders(id: "atlassian")
        atlassian.answers["jira_issue"] = ticket("KAN-12")
        let (agents, _) = makeAgents([atlassian])
        #expect(await agents.storedTicket("KAN-12")?["summary"] == "Retry failed renewals")
        let (alone, _) = makeAgents()
        #expect(await alone.storedTicket("KAN-12") == nil)
    }

    @Test func linkingAWorktreeFetchesNothing() async throws {
        let suite = "agents-offline-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let tree = Worktree(path: "/code/billing-api/.worktrees/KAN-12-retry", repo: "/code/billing-api", slug: "acme/billing-api", branch: "KAN-12-retry",
                            head: "abc", isMain: false, changed: 0, untracked: 0, upstream: nil, ahead: 0, behind: 0, base: "origin/main",
                            baseAhead: 1, baseBehind: 0, lastCommitAt: nil, lastCommit: "Retry", scannedAt: .now)
        defaults.set(try JSONEncoder().encode([tree]), forKey: "agents.worktrees.items")
        let pulls = FakeReaders(id: "pull-requests")
        pulls.answers["github_list_prs"] = []
        pulls.fetcherNames = ["github.branch_pulls"]
        let host = try TestHost([pulls])
        let store = WorktreeStore(defaults: defaults)

        await store.link(tree.path, to: nil, host: host)
        #expect(pulls.calls == ["github_list_prs"])
        // The scan (not Dashii) may fetch a branch's merged or closed PRs.
        await store.refreshPulls(host: host)
        #expect(pulls.calls.contains("github.branch_pulls"))
    }

    @Test func noToolDashiiGetsMakesARequest() async throws {
        let atlassian = FakeReaders(id: "atlassian")
        atlassian.answers["jira_issue"] = notFetched("jira.issue", input: ["key": "KAN-12"])
        let (agents, _) = makeAgents([atlassian, FakeIntegration(id: "github", baseURL: URL(string: "https://github-sentinel.test")!)])
        let values: [String: JSONValue] = ["issue_key": "KAN-12", "session_id": .string(UUID().uuidString), "repo": "acme/billing-api", "branch": "main", "path": "/code/x"]
        #expect(await NetworkSentinel.requests(running: agents.tools, values: values) == [])
    }
}
