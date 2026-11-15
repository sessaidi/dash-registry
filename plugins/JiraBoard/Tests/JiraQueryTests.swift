import DashKit
import Foundation
import Testing

/// Jira in DashQL: the `jira` dataset and the board widget's query.
@MainActor
struct JiraQueryTests {
    private func issue(_ key: String, _ summary: String, status: String, category: String, assignee: String?) throws -> JiraIssue {
        let json = try JSONValue.parse(Data(issueJSON(key, summary: summary, status: status, category: category, assignee: assignee).utf8))
        return JiraIssue(JiraClient.Issue(json: json), url: URL(string: "https://acme.atlassian.net/browse/\(key)")!)
    }

    @Test func datasetAndWidgetQuery() async throws {
        let (feature, host, _) = makeFeature(host: "query.atlassian.net")
        let issues = [try issue("KAN-1", "Crash on start", status: "In Progress", category: "indeterminate", assignee: "Maya Chen"),
                      try issue("KAN-2", "Write docs", status: "Done", category: "done", assignee: "Sam Ortiz"),
                      try issue("OPS-3", "Rotate creds", status: "To Do", category: "new", assignee: nil)]
        issues.forEach(host.context.insert)
        try host.context.save()

        let dataset = try #require(feature.datasets.first { $0.name == "jira" })
        let rows = try await dataset.rows(nil)
        #expect(Set(rows.compactMap { $0["key"]?.string }) == ["KAN-1", "KAN-2", "OPS-3"])
        #expect(rows.first { $0["key"] == "KAN-1" }?["url"] == "https://acme.atlassian.net/browse/KAN-1")

        let open = try await QueryEngine(datasets: feature.datasets).run("jira project:KAN -category:done | select key, assignee")
        #expect(open.rows == [["key": "KAN-1", "assignee": "Maya Chen"]])

        let tickets = issues.map(JiraTicket.init)
        let query = try #require(try WidgetQuery("where assignee is null or status = Done | sort key", fields: JiraBoardWidget.queryFields))
        let kept = await query.apply(to: tickets) { ticket in issues.first { $0.key == ticket.key }!.queryRow }
        #expect(kept.map(\.key) == ["KAN-2", "OPS-3"])
    }
}
