import DashKit
import DashKitTesting
import Foundation
import Testing

/// Tools that ask a service; the standup must leave them to the user.
@MainActor
private final class ServiceTools: DashExtension {
    let id = "github"
    let name = "GitHub"
    let systemImage = "link"
    private(set) var ran: [String] = []
    var tools: [DashiiTool] {
        [
            DashiiTool(name: "github_list_prs", description: "", callsService: true) { [weak self] _ in
                self?.ran.append("github_list_prs")
                return []
            },
            DashiiTool(name: "jira_list_issues", description: "") { [weak self] _ in
                self?.ran.append("jira_list_issues")
                return []
            },
        ]
    }
}

/// The standup reads what Dash already has: it never runs a tool that calls a service.
@MainActor
struct StandupOfflineTests {
    private func make() throws -> (DailyStandupFeature, ServiceTools, TestHost) {
        let standup = DailyStandupFeature(defaults: UserDefaults(suiteName: "standup-\(UUID().uuidString)")!)
        let service = ServiceTools()
        let host = try TestHost([service, standup])
        host.start([service, standup])
        standup.stop()
        return (standup, service, host)
    }

    @Test func onlyToolsDashiiMayRun() async throws {
        let (standup, service, host) = try make()
        defer { _ = host }
        #expect(try await standup.tool("github_list_prs") == nil)
        #expect(try await standup.tool("jira_list_issues") == [])
        _ = await standup.evidence(since: .now.addingTimeInterval(-86_400))
        #expect(!service.ran.contains("github_list_prs") && service.ran.contains("jira_list_issues"))
    }

    @Test func noToolMakesARequest() async throws {
        let (standup, _, host) = try make()
        defer { _ = host }
        #expect(await NetworkSentinel.requests(running: standup.tools, values: ["date": "2026-11-18", "days": 3]) == [])
    }
}
