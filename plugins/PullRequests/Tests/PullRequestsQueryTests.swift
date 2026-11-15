import DashKit
import Foundation
import Testing

/// Pull requests in DashQL: the `prs` dataset, ticket keys, and the widget's query.
@MainActor
struct PullRequestsQueryTests {
    @Test func datasetTicketsAndWidgetQuery() async throws {
        let harness = Harness()
        let fix = PullRequest(uid: "acme/api#1", repo: "acme/api", number: 1)
        fix.title = "KAN-12: fix crash on start"
        fix.headRef = "kan-12-crash"
        fix.author = "maya"
        let docs = PullRequest(uid: "acme/api#2", repo: "acme/api", number: 2)
        docs.title = "Docs for the release"
        docs.headRef = "OPS-7-docs"
        docs.isDraft = true
        harness.host.context.insert(fix)
        harness.host.context.insert(docs)
        let review = PRReview(prUID: fix.uid, headSHA: "abc", model: "test")
        review.verdict = "request_changes"
        review.risk = "high"
        harness.host.context.insert(review)
        try harness.host.context.save()

        #expect(fix.ticketKeys == ["KAN-12"] && docs.ticketKeys == ["OPS-7"])
        let rows = try await #require(harness.feature.datasets.first { $0.name == "prs" }).rows(nil)
        #expect(rows.first { $0["number"] == 1 }?["risk"] == "high")

        let risky = try await QueryEngine(datasets: harness.feature.datasets).run("prs risk:high | select repo, number, tickets")
        #expect(risky.rows == [["repo": "acme/api", "number": 1, "tickets": ["KAN-12"]]])

        let query = try #require(try WidgetQuery("draft=true", fields: PullRequestsWidget.queryFields))
        #expect(await query.apply(to: [fix, docs]) { $0.queryRow(review: nil) }.map(\.number) == [2])
    }
}
