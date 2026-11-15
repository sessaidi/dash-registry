import DashKit
import DashKitTesting
import Foundation
import SwiftUI
import Testing

@MainActor
struct BackendMeetingTests {
    private func make(jira: Bool = true) throws -> (BackendMeetingFeature, TestHost, String, String, URL) {
        let gh = "gh-\(UUID().uuidString.prefix(8)).test"
        let atl = "atl-\(UUID().uuidString.prefix(8)).test"
        let folder = FileManager.default.temporaryDirectory.appending(path: "backend-meeting-\(UUID().uuidString)")
        let feature = BackendMeetingFeature(defaults: UserDefaults(suiteName: "backend-meeting-\(UUID().uuidString)")!)
        feature.outputFolder = folder.path
        var items: [any DashExtension] = [TestIntegration(id: "github", baseURL: URL(string: "https://\(gh)")!, exports: ["login": "me"]), feature]
        if jira { items.insert(TestIntegration(id: "atlassian", baseURL: URL(string: "https://\(atl)")!), at: 0) }
        let host = try TestHost(items)
        host.start(items)
        return (feature, host, gh, atl, folder)
    }

    nonisolated private static let searchBody = """
        {"items": [
          {"number": 12, "title": "LAF-12 renew subscriptions", "state": "closed", "html_url": "https://github.com/acme/api/pull/12",
           "repository_url": "https://api.github.com/repos/acme/api", "updated_at": "2026-11-10T10:00:00Z", "pull_request": {"merged_at": "2026-11-10T10:00:00Z"}},
          {"number": 13, "title": "LAF-13 observability", "state": "open", "draft": false, "html_url": "https://github.com/acme/api/pull/13",
           "repository_url": "https://api.github.com/repos/acme/api", "updated_at": "2026-11-11T10:00:00Z", "pull_request": {"merged_at": null}},
          {"number": 14, "title": "abandoned", "state": "closed", "html_url": "https://github.com/acme/api/pull/14",
           "repository_url": "https://api.github.com/repos/acme/api", "updated_at": "2026-11-09T10:00:00Z", "pull_request": {"merged_at": null}},
          {"number": 15, "title": "an issue, not a PR", "state": "open", "html_url": "https://github.com/acme/api/issues/15",
           "repository_url": "https://api.github.com/repos/acme/api", "updated_at": "2026-11-09T10:00:00Z"}
        ]}
        """

    private func serveGitHub(_ host: String) {
        StubHTTP.serve(host) { request in
            switch request.url?.path() ?? "" {
            case "/user/orgs": (200, Data(#"[{"login": "acme"}]"#.utf8), [:])
            case "/search/issues": (200, Data(Self.searchBody.utf8), [:])
            default: (404, Data(), [:])
            }
        }
    }

    private func serveJira(_ host: String) {
        StubHTTP.serve(host, json: """
            {"issues": [{"key": "LAF-12", "fields": {"summary": "Renewals", "status": {"name": "Done", "statusCategory": {"key": "done"}},
             "issuetype": {"name": "Story"}, "project": {"name": "Laf"}, "resolutiondate": "2026-11-10"}}]}
            """)
    }

    @Test func rangeStartsAtTheLastReportOrTheCycle() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!
        let cycle = ReportRange.make(cycleWeeks: 2, sinceLastReport: true, lastEnd: nil, now: now, calendar: calendar)
        #expect(ReportRange.day(cycle.start, calendar: calendar) == "2026-11-01")
        let last = ISO8601DateFormatter().date(from: "2026-11-08T09:00:00Z")!
        let since = ReportRange.make(cycleWeeks: 2, sinceLastReport: true, lastEnd: last, now: now, calendar: calendar)
        #expect(ReportRange.day(since.start, calendar: calendar) == "2026-11-08" && since.end == now)
        let fixed = ReportRange.make(cycleWeeks: 4, sinceLastReport: false, lastEnd: last, now: now, calendar: calendar)
        #expect(ReportRange.day(fixed.start, calendar: calendar) == "2026-10-18")
        // Capped: ten weeks at most, and 1–10 weeks.
        let old = ISO8601DateFormatter().date(from: "2025-01-01T00:00:00Z")!
        #expect(ReportRange.day(ReportRange.make(cycleWeeks: 2, sinceLastReport: true, lastEnd: old, now: now, calendar: calendar).start, calendar: calendar) == "2026-09-06")
        #expect(ReportRange.day(ReportRange.make(cycleWeeks: 40, sinceLastReport: false, lastEnd: nil, now: now, calendar: calendar).start, calendar: calendar) == "2026-09-06")
    }

    @Test func pullsAreClassifiedAndDeduplicated() async throws {
        let (feature, host, gh, _, _) = try make(jira: false)
        defer { withExtendedLifetime(host) {} }
        serveGitHub(gh)
        let range = ReportRange(start: .now.addingTimeInterval(-14 * 86400), end: .now)
        let pulls = try await feature.pullRequests(range: range)
        // Same items from the org-less and the org query: kept once; the issue is dropped.
        #expect(pulls.map(\.number) == [13, 12, 14])
        #expect(pulls.map(\.state) == [.open, .merged, .closed])
        #expect(pulls.first?.repo == "acme/api" && pulls.first?.tickets == ["LAF-13"])
        let queries = StubHTTP.requests(gh).compactMap { request in
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        }
        #expect(queries.count == 2 && queries.allSatisfy { $0.hasPrefix("author:me is:pr updated:") })
        #expect(queries.last?.hasSuffix(" org:acme") == true)
        // Read-only: only GETs.
        #expect(StubHTTP.requests(gh).allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }

    @Test func generatesStoresAndWritesTheReport() async throws {
        let (feature, host, gh, atl, folder) = try make()
        defer { try? FileManager.default.removeItem(at: folder) }
        serveGitHub(gh)
        serveJira(atl)
        host.activity.emit("agent.pr_opened", source: "agents", title: "Draft PR opened for LAF-13", importance: .notable)
        host.testDashii.reply = "```markdown\n- **Renewals**: subscriptions renew automatically\n- **In chantier**:\n  - observability on renewals (open PR)\n```"
        let range = feature.nextRange(cycleWeeks: 2, sinceLastReport: true)
        let report = try await feature.generate(range: range, cycleWeeks: 2)

        #expect(report.markdown == "- **Renewals**: subscriptions renew automatically\n- **In chantier**:\n  - observability on renewals (open PR)")
        let call = try #require(host.testDashii.calls.last)
        #expect(call.system.contains("In chantier") && call.system.contains("Debug & Fix") && call.system.contains("English"))
        let data = try JSONValue.parse(Data(call.prompt.utf8))
        // Closed-unmerged PRs never reach Claude.
        #expect(data["pull_requests"]?.array?.compactMap { $0["number"]?.int } == [13, 12])
        #expect(data["tickets"]?.array?.first?["key"] == "LAF-12")
        #expect(data["dash_activity"]?.array?.first?["title"] == "Draft PR opened for LAF-13")
        #expect(StubHTTP.requests(atl).first?.url?.query()?.contains("currentUser") == true)

        // Stored: the next report starts where this one ended.
        #expect(feature.reports().map(\.id) == [report.id])
        #expect(feature.nextRange(cycleWeeks: 2, sinceLastReport: true).start == Calendar.current.startOfDay(for: range.end))
        // Written like the skill: fait-marquant-<start>-to-<end>.md.
        let file = try #require(feature.fileURL(for: report))
        #expect(file.lastPathComponent == "fait-marquant-\(range.startDay)-to-\(range.endDay).md")
        #expect(try String(contentsOf: file, encoding: .utf8).hasPrefix("# Fait marquant — \(range.startDay) → \(range.endDay)\n\n- **Renewals**"))
        #expect(host.activity.events.contains { $0.kind == "backend-meeting.report" })

        let listed = try await host.runTool("backend_meeting_reports")
        #expect(listed?.array?.first?["markdown"]?.string == report.markdown)
    }

    @Test func jiraIsOptional() async throws {
        let (feature, host, gh, _, folder) = try make(jira: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        serveGitHub(gh)
        host.testDashii.reply = "- **Renewals**: done"
        _ = try await feature.generate(range: feature.nextRange(cycleWeeks: 1, sinceLastReport: false), cycleWeeks: 1)
        let data = try JSONValue.parse(Data(try #require(host.testDashii.calls.last).prompt.utf8))
        #expect(data["tickets"] == nil)
        #expect(feature.requires == ["github"] && feature.optional == ["atlassian"])
    }

    @Test func markdownLines() {
        let lines = ReportMarkdown.lines("- **A**: one\n- **In chantier**:\n  - x\n\n- **Debug & Fix**")
        #expect(lines == [.init(level: 0, text: "**A**: one"), .init(level: 0, text: "**In chantier**:"), .init(level: 1, text: "x"), .init(level: 0, text: "**Debug & Fix**")])
    }

    @Test func contracts() {
        let feature = BackendMeetingFeature(defaults: UserDefaults(suiteName: "backend-meeting-\(UUID().uuidString)")!)
        #expect(feature.id == "backend-meeting" && feature.metadata.version == "1.0.0" && feature.metadata.minimumDashKit == "1.5.0")
        #expect(feature.defaultCycleWeeks == 2)
        #expect(feature.tools.allSatisfy { !$0.requiresApproval && !$0.writesRemotely })
        #expect(BackendMeetingWidget.kind == "backend-meeting.report")
        #expect(BackendMeetingWidget.defaultConfig == .init(cycleWeeks: 2, sinceLastReport: true))
        #expect(WidgetType(BackendMeetingWidget.self).preview != nil)
        #expect(BackendMeetingPlugin.makeExtensions().map(\.id) == ["backend-meeting"])
        #expect(BackendMeetingFeature.ticketsJQL(range: ReportRange(start: .now, end: .now)).hasPrefix("assignee = currentUser() AND updated >= "))
    }
}
