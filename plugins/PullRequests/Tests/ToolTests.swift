import DashKit
import DashKitUI
import Foundation
import Testing

/// Claude tools and the widget, on a fake host with a stubbed GitHub.
@MainActor
struct ToolTests {
    /// Three open PRs on acme/api: #1 mine, #2 requests my review (reviewed by Claude), #3 neither.
    func seeded() async throws -> Harness {
        let harness = Harness(autoReview: false)
        harness.dashii.reply = Fixtures.review
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(
                Fixtures.pull(1, sha: "a1", author: "me", updated: "2026-11-10T09:00:00Z"),
                Fixtures.pull(2, sha: "b1", requested: ["me"], updated: "2026-11-10T11:00:00Z"),
                Fixtures.pull(3, sha: "c1", updated: "2026-11-10T10:00:00Z"))),
            "/repos/acme/api/pulls/2": .text("+x\n"),
        ])
        await harness.feature.sync()
        harness.feature.requestReview(try #require(harness.feature.pull("acme/api#2")))
        await harness.feature.reviewsFinished()
        return harness
    }

    @Test func listPRsFiltersAndIncludesTheLatestReview() async throws {
        let harness = try await seeded()
        let list = try harness.tool("github_list_prs")
        let all = try #require(try await list.run([:]).array)
        #expect(all.map { $0["number"]?.int } == [2, 3, 1])
        #expect(all[0]["dashii_review"] == ["status": "done", "verdict": "request_changes", "risk": "high"])
        #expect(all[1]["dashii_review"] == .null)
        #expect(all[0]["url"] == "https://github.com/acme/api/pull/2" && all[0]["draft"] == false)
        #expect(try await list.run(["filter": "mine"]).array?.map { $0["number"]?.int } == [1])
        #expect(try await list.run(["filter": "review_requested"]).array?.map { $0["number"]?.int } == [2])
        #expect(try await list.run(["repo": "acme/web"]).array?.isEmpty == true)
        await #expect(throws: ToolError.self) { _ = try await list.run(["repo": 5]) }
    }

    @Test func getPRCombinesLiveDataAndTheClaudeReview() async throws {
        let harness = try await seeded()
        harness.serve([
            "/repos/acme/api/pulls/2": .json(#"{"title":"T","body":"B","user":{"login":"octocat"},"state":"open","mergeable_state":"clean","head":{"ref":"h"},"base":{"ref":"main"}}"#),
            "/repos/acme/api/pulls/2/files": .json(#"[{"filename":"a.swift","status":"added","additions":4,"deletions":0,"patch":"…"}]"#),
            "/repos/acme/api/pulls/2/reviews": .json(#"[{"user":{"login":"bob"},"state":"CHANGES_REQUESTED","body":"no","id":9}]"#),
            "/repos/acme/api/issues/2/comments": .json("[" + (1...25).map { #"{"user":{"login":"u\#($0)"},"body":"c\#($0)"}"# }.joined(separator: ",") + "]"),
        ])
        let result = try await harness.tool("github_get_pr").run(["repo": "acme/api", "number": 2])
        #expect(result["title"] == "T" && result["author"] == "octocat" && result["mergeable_state"] == "clean")
        #expect(result["head"] == "h" && result["base"] == "main")
        #expect(result["files"] == [["file": "a.swift", "status": "added", "additions": 4, "deletions": 0]])
        #expect(result["reviews"] == [["user": "bob", "state": "CHANGES_REQUESTED", "body": "no"]])
        // Only the last 20 comments.
        #expect(result["comments"]?.array?.count == 20 && result["comments"]?[0]?["body"] == "c6")
        #expect(result["dashii_review"]?["verdict"] == "request_changes")
        #expect(result["dashii_review"]?["findings"]?.array?.count == 2)
    }

    @Test func getDiffTruncatesLargeDiffs() async throws {
        let harness = Harness(autoReview: false)
        harness.serve(["/repos/acme/api/pulls/1": .text("+small\n"), "/repos/acme/api/pulls/2": .text(String(repeating: "x", count: 200_005))])
        let tool = try harness.tool("github_get_diff")
        #expect(try await tool.run(["repo": "acme/api", "number": 1]) == ["truncated": false, "diff": "+small\n"])
        let big = try await tool.run(["repo": "acme/api", "number": 2])
        #expect(big["truncated"] == true && big["total_characters"] == 200_005 && big["diff"]?.string?.count == 200_000)
    }

    @Test func rerunReviewQueuesOnlyWatchedPRs() async throws {
        let harness = try await seeded()
        let tool = try harness.tool("github_rerun_review")
        await #expect(throws: ToolError("That PR is not in the watched list.")) { _ = try await tool.run(["repo": "acme/api", "number": 99]) }
        harness.serve(["/repos/acme/api/pulls/3": .text("+y\n")])
        #expect(try await tool.run(["repo": "acme/api", "number": 3]) == "queued")
        #expect(harness.feature.latestReview("acme/api#3")?.status == "queued")
        await harness.feature.reviewsFinished()
        #expect(harness.feature.latestReview("acme/api#3")?.status == "done")
    }

    @Test func reviewsAreNeverPostedToGitHub() throws {
        let harness = Harness(autoReview: false)
        let names = harness.feature.tools.map(\.name)
        #expect(!names.contains("github_comment") && !names.contains("github_submit_review"))
        #expect(!names.contains { $0.contains("comment") || $0.contains("submit") })
    }

    @Test func createPRDefaultsToTheDefaultBranchAndDraft() async throws {
        let harness = Harness(autoReview: false)
        harness.serve([
            "GET /repos/acme/api": .json(#"{"default_branch":"develop"}"#),
            "POST /repos/acme/api/pulls": .json(#"{"number":12,"html_url":"https://github.com/acme/api/pull/12"}"#, status: 201),
        ])
        let tool = try harness.tool("github_create_pr")
        let created = try await tool.run(["repo": "acme/api", "head": "feature", "title": "T", "body": "B"])
        #expect(created == ["url": "https://github.com/acme/api/pull/12", "number": 12])
        #expect(harness.requests.last?.bodyJSON == ["title": "T", "head": "feature", "base": "develop", "body": "B", "draft": true])

        _ = try await tool.run(["repo": "acme/api", "head": "feature", "base": "release", "title": "T", "body": "B", "draft": false])
        #expect(harness.requests.last?.bodyJSON?["base"] == "release" && harness.requests.last?.bodyJSON?["draft"] == false)
        #expect(harness.requests.filter { $0.url?.path() == "/repos/acme/api" }.count == 1)
    }

    @Test func toolsNeedTheGitHubConnection() async throws {
        let harness = Harness(autoReview: false)
        harness.github.isConnected = false
        await #expect(throws: ToolError("Connect GitHub in Settings › Integrations.")) {
            _ = try await harness.tool("github_get_diff").run(["repo": "acme/api", "number": 1])
        }
        harness.host.extensions.removeAll { $0.id == "github" }
        await #expect(throws: ToolError("The GitHub integration is not installed.")) {
            _ = try await harness.tool("github_get_diff").run(["repo": "acme/api", "number": 1])
        }
    }

    // MARK: Widget

    @Test func widgetKeepsItsKindLimitsAndConfig() throws {
        let widget = WidgetType(PullRequestsWidget.self)
        #expect(widget.kind == "github.pulls" && widget.defaultSize == .large && widget.hasSettings)
        #expect(widget.sizeLimits == GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 24))
        #expect(widget.defaultConfig == ["repo": "", "filter": "all"])
        #expect(widget.preview != nil)
        #expect(throws: ToolError.self) { _ = try widget.normalize(["repo": 1]) }
    }

    @Test func widgetSnapshotRunsTheListTool() async throws {
        let harness = try await seeded()
        let context = WidgetContext(widgetID: UUID(), host: harness.host)
        let mine = await PullRequestsWidget.snapshot(config: .init(repo: "", filter: "mine"), context: context)
        #expect(mine["pull_requests"]?.array?.map { $0["number"]?.int } == [1])
        #expect(mine["explanation"]?.string?.contains("review_requested") == true)
        let scoped = await PullRequestsWidget.snapshot(config: .init(repo: "acme/api", filter: "all"), context: context)
        #expect(scoped["pull_requests"]?.array?.count == 3)
    }

    @Test func dashiiSearchesFiltersAndOpensPRs() throws {
        #expect(PullRequestsWidget.actions.map(\.name) == ["search", "set_filter", "set_repo", "select", "clear_selection", "clear"])
        #expect(PullRequestsWidget.actions.filter { ["set_filter", "set_repo"].contains($0.name) }.allSatisfy { $0.description.contains("Temporary") })
        let pulls = PullRequestSamples.pulls()
        var config = PullRequestsWidget.defaultConfig
        var search = ""
        let found = try PullRequestsWidgetActions.perform("search", ["text": "checkout"], config: &config, search: &search, pulls: pulls)
        #expect(search == "checkout" && found.reply["matches"] == 1)
        #expect(PullRequestsWidgetActions.matches(pulls[0], search: "#482") && !PullRequestsWidgetActions.matches(pulls[1], search: "#482"))
        _ = try PullRequestsWidgetActions.perform("set_filter", ["filter": "mine"], config: &config, search: &search, pulls: pulls)
        #expect(config.filter == "mine")
        #expect(throws: ToolError.self) { try PullRequestsWidgetActions.perform("set_filter", ["filter": "everything"], config: &config, search: &search, pulls: pulls) }
        _ = try PullRequestsWidgetActions.perform("set_repo", ["repo": "acme/web"], config: &config, search: &search, pulls: pulls)
        #expect(config.repo == "acme/web")
        #expect(try PullRequestsWidgetActions.perform("select", ["pr": "acme/orders#479"], config: &config, search: &search, pulls: pulls).select?.number == 479)
        #expect(try PullRequestsWidgetActions.perform("select", ["pr": "1207"], config: &config, search: &search, pulls: pulls).select?.number == 1207)
        #expect(try PullRequestsWidgetActions.perform("select", ["pr": "tax rounding"], config: &config, search: &search, pulls: pulls).select?.number == 479)
        #expect(throws: ToolError.self) { try PullRequestsWidgetActions.perform("select", ["pr": "#9999"], config: &config, search: &search, pulls: pulls) }
        _ = try PullRequestsWidgetActions.perform("clear", [:], config: &config, search: &search, pulls: pulls)
        #expect(search.isEmpty && config == PullRequestsWidget.defaultConfig)
    }

    @Test func previewSamplesAreSelfContained() {
        let pulls = PullRequestSamples.pulls()
        let reviews = PullRequestSamples.reviews()
        #expect(pulls.count == 4 && Set(pulls.map(\.uid)).count == 4)
        #expect(pulls.allSatisfy { $0.headSHA.count == 40 && !$0.title.isEmpty && $0.url.hasPrefix("https://github.com/") })
        #expect(pulls.contains { $0.isDraft } && pulls.contains { $0.isMine } && pulls.contains { $0.reviewRequested })
        // Each review belongs to a sample PR, at its head commit.
        for review in reviews {
            let pr = pulls.first { $0.uid == review.prUID }
            #expect(pr?.headSHA == review.headSHA)
        }
        let done = reviews.first { $0.verdict == "request_changes" }
        #expect(done?.findings.count == 2 && done?.markdown.contains("| major |") == true)
        let mine = pulls.filter { PullRequestsWidget.matches($0, .init(repo: "", filter: "mine")) }
        #expect(mine.map(\.number) == [479])
        _ = PullRequestsWidget.preview(config: PullRequestsWidget.defaultConfig)
    }
}
