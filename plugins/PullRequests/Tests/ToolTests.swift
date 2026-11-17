import DashKit
import DashKitTesting
import DashKitUI
import Foundation
import SwiftData
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
        #expect(all.allSatisfy { $0["synced_at"]?.string != nil })
        #expect(try await list.run(["filter": "mine"]).array?.map { $0["number"]?.int } == [1])
        #expect(try await list.run(["filter": "review_requested"]).array?.map { $0["number"]?.int } == [2])
        #expect(try await list.run(["repo": "acme/web"]).array?.isEmpty == true)
        await #expect(throws: ToolError.self) { _ = try await list.run(["repo": 5]) }
    }

    @Test func getPRReadsTheFetchedPRAndTheDashiiReview() async throws {
        let harness = try await seeded()
        harness.serve([
            "/repos/acme/api/pulls/2": .json(#"{"title":"T","body":"Set GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789","user":{"login":"octocat"},"state":"open","mergeable_state":"clean","head":{"ref":"h"},"base":{"ref":"main"}}"#),
            "/repos/acme/api/pulls/2/files": .json(#"[{"filename":"a.swift","status":"added","additions":4,"deletions":0,"patch":"…"}]"#),
            "/repos/acme/api/pulls/2/reviews": .json(#"[{"user":{"login":"bob"},"state":"CHANGES_REQUESTED","body":"no","id":9}]"#),
            "/repos/acme/api/issues/2/comments": .json("[" + (1...25).map { #"{"user":{"login":"u\#($0)"},"body":"c\#($0)"}"# }.joined(separator: ",") + "]"),
        ])
        let reader = try harness.tool("github_get_pr")
        // Not fetched yet: the hint, and Dash's own review all the same.
        let before = try await reader.run(["repo": "acme/api", "number": 2])
        #expect(before["fetched"] == false && before["refresh"] == ["fetcher": "github.pr", "input": ["repo": "acme/api", "number": 2]])
        #expect(before["dashii_review"]?["verdict"] == "request_changes")

        let receipt = try await harness.host.fetch("github.pr", ["repo": "Acme/API", "number": 2])
        #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0 && receipt["synced_at"]?.string != nil)
        #expect(receipt["keys"]?[0]?.string?.hasPrefix("github.pr/") == true)
        #expect(receipt["read_with"] == #"github_get_pr {"number":2,"repo":"acme/api"}"#)
        let paths = harness.requests.compactMap { $0.url?.path() }
        #expect(paths.contains("/repos/acme/api/pulls/2/files") && paths.contains("/repos/acme/api/issues/2/comments"))

        let result = try await reader.run(["repo": "acme/api", "number": 2])
        #expect(result["title"] == "T" && result["author"] == "octocat" && result["mergeable_state"] == "clean")
        #expect(result["head"] == "h" && result["base"] == "main")
        #expect(result["files"] == [["file": "a.swift", "status": "added", "additions": 4, "deletions": 0]])
        #expect(result["reviews"] == [["user": "bob", "state": "CHANGES_REQUESTED", "body": "no"]])
        // Only the last 20 comments.
        #expect(result["comments"]?.array?.count == 20 && result["comments"]?[0]?["body"] == "c6")
        #expect(result["dashii_review"]?["verdict"] == "request_changes")
        #expect(result["dashii_review"]?["findings"]?.array?.count == 2)
        #expect(result["stale"] == false && result["synced_at"]?.string != nil && result["refresh"]?["fetcher"] == "github.pr")
        // Secrets never reach the mirror (or Dashii).
        let stored = harness.host.synced.records(kind: "github.pr", scope: harness.feature.storeScope)
        #expect(stored.count == 1 && stored.allSatisfy { !$0.value.jsonString().contains("ghp_") && $0.source == "pull-requests" })
        #expect(!result.jsonString().contains("ghp_"))

        #expect(try await harness.host.fetch("github.pr", ["repo": "acme/api", "number": 2])["unchanged"] == 1)
        harness.feature.now = { .now.addingTimeInterval(11 * 60) }
        #expect(try await reader.run(["repo": "acme/api", "number": 2])["stale"] == true)
        await #expect(throws: ToolError("Give repo as owner/name.")) { _ = try await reader.run(["repo": "../x", "number": 2]) }
        await #expect(throws: ToolError("Give repo and number.")) { _ = try await reader.run(["repo": "acme/api"]) }
    }

    @Test func getDiffReadsTheFetchedDiffCutUnderTheCap() async throws {
        let harness = Harness(autoReview: false)
        harness.serve(["/repos/acme/api/pulls/1": .text("+small\n"), "/repos/acme/api/pulls/2": .text(String(repeating: "x", count: 200_005))])
        let tool = try harness.tool("github_get_diff")
        #expect(try await tool.run(["repo": "acme/api", "number": 1])["hint"] == "Call data_fetch with fetcher github.pr_diff")
        _ = try await harness.host.fetch("github.pr_diff", ["repo": "acme/api", "number": 1])
        _ = try await harness.host.fetch("github.pr_diff", ["repo": "acme/api", "number": 2])
        #expect(harness.requests.allSatisfy { $0.value(forHTTPHeaderField: "Accept") == "application/vnd.github.diff" })
        let small = try await tool.run(["repo": "acme/api", "number": 1])
        #expect(small["truncated"] == false && small["diff"] == "+small\n" && small["stale"] == false)
        let big = try await tool.run(["repo": "acme/api", "number": 2])
        #expect(big["truncated"] == true && big["total_characters"] == 200_005 && big["diff"]?.string?.count == 190_000)
        let stored = harness.host.synced.records(kind: "github.pr_diff", scope: harness.feature.storeScope)
        #expect(stored.count == 2 && stored.allSatisfy { $0.value.jsonString().utf8.count < 200_000 })
    }

    // MARK: No network for Dashii and agents

    @Test func noToolDashiiGetsCallsGitHub() async throws {
        let harness = try await seeded()
        let values: [String: JSONValue] = ["repo": "acme/api", "number": 2, "branch": "feature-2"]
        // A queued review runs later as the feature's own job (it fetches the diff); only the queueing is the tool's.
        let inputs: [String: JSONValue] = ["github_rerun_review": ["repo": "acme/api", "number": 99]]
        #expect(await NetworkSentinel.requests(running: harness.feature.tools, values: values, inputs: inputs) == [])
        // With data stored, the readers still only read.
        harness.serve([
            "/repos/acme/api/pulls/2": .json(#"{"title":"T"}"#), "/repos/acme/api/pulls/2/files": .json("[]"),
            "/repos/acme/api/pulls/2/reviews": .json("[]"), "/repos/acme/api/issues/2/comments": .json("[]"),
            "/repos/acme/api/pulls": .json("[]"),
        ])
        _ = try await harness.host.fetch("github.pr", ["repo": "acme/api", "number": 2])
        _ = try await harness.host.fetch("github.branch_pulls", ["repo": "acme/api", "branch": "feature-2"])
        #expect(await NetworkSentinel.requests(running: harness.feature.tools, values: values, inputs: inputs) == [])
        // Opening a PR is the user's: Dashii and agents never get it.
        let remote = harness.feature.tools.filter { !$0.isForDashii }
        #expect(remote.map(\.name) == ["github_create_pr"] && remote.allSatisfy { $0.writesRemotely && $0.requiresApproval })
    }

    @Test func fetchersAndVerbsLineUp() throws {
        let harness = Harness(autoReview: false)
        #expect(harness.feature.fetchers.map(\.name) == ["github.pr", "github.pr_diff", "github.branch_pulls"])
        let readers = harness.feature.tools.filter(\.isForDashii).map(\.name)
        #expect(harness.feature.verbs.allSatisfy { readers.contains($0.tool) })
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

    @Test func aChatReviewIsStoredOnThePRBesideTheAutomaticOne() async throws {
        let harness = try await seeded()
        let before = harness.requests.count
        let saved = try await harness.tool("pull_request_save_review").run([
            "repo": "acme/api", "number": 2, "verdict": "approve", "risk": "low", "summary": "Looks right.",
            "findings": [["file": "a.swift", "line": 3, "severity": "nit", "title": "Name", "detail": "Unclear.", "suggestion": ""]],
        ])
        #expect(saved["posted_to_github"] == false)
        let latest = try #require(harness.feature.latestReview("acme/api#2"))
        #expect(latest.isFromChat && latest.verdict == "approve" && latest.findings.first?.title == "Name")
        // The automatic review of the same commit is kept, and nothing went to GitHub.
        let all = try harness.host.context.fetch(FetchDescriptor<PRReview>(predicate: #Predicate { $0.prUID == "acme/api#2" }))
        #expect(all.count == 2 && all.contains { !$0.isFromChat && $0.verdict == "request_changes" })
        #expect(harness.requests.count == before)
        await #expect(throws: ToolError.self) {
            _ = try await harness.tool("pull_request_save_review").run(["repo": "acme/api", "number": 99, "verdict": "comment", "risk": "low", "summary": "x"])
        }
    }

    @Test func branchPullsAreFetchedIntoTheMirror() async throws {
        let harness = Harness(autoReview: false)
        harness.serve([
            "/repos/acme/api/pulls": .json(#"[{"number":790,"title":"Read the flag once","html_url":"https://github.com/acme/api/pull/790","state":"closed","merged_at":"2026-11-10T10:00:00Z","draft":false,"updated_at":"2026-11-10T10:00:00Z"}]"#),
        ])
        let fetcher = try #require(harness.feature.fetchers.first { $0.name == "github.branch_pulls" })
        let reader = try harness.tool("github_branch_pulls")
        let input: JSONValue = ["repo": "acme/api", "branch": "KAN-3-flags"]
        #expect(try await reader.run(input)["refresh"] == ["fetcher": "github.branch_pulls", "input": input])
        let receipt = try await fetcher.fetch(input)
        // The Agents plugin reads `pulls` from the receipt.
        #expect(receipt["pulls"]?[0]?["merged"] == true && receipt["pulls"]?[0]?["number"] == 790)
        #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0 && receipt["keys"] == ["github.branch_pulls/acme/api/KAN-3-flags"])
        #expect(receipt["read_with"] == #"github_branch_pulls {"branch":"KAN-3-flags","repo":"acme/api"}"#)
        #expect(harness.requests.last?.url?.query()?.contains("head=acme:KAN-3-flags") == true)
        #expect(harness.host.synced.record(kind: "github.branch_pulls", scope: "acme/api", key: "KAN-3-flags") != nil)
        let read = try await reader.run(input)
        #expect(read["items"]?[0]?["number"] == 790 && read["stale"] == false)
        #expect(try await fetcher.fetch(input)["unchanged"] == 1)
        await #expect(throws: ToolError.self) { _ = try await fetcher.fetch(["repo": "api", "branch": "x"]) }
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

    @Test func fetchersNeedTheGitHubConnection() async throws {
        let harness = Harness(autoReview: false)
        harness.github.isConnected = false
        await #expect(throws: ToolError("Connect GitHub in Settings › Integrations.")) {
            _ = try await harness.host.fetch("github.pr_diff", ["repo": "acme/api", "number": 1])
        }
        harness.host.extensions.removeAll { $0.id == "github" }
        await #expect(throws: ToolError("The GitHub integration is not installed.")) {
            _ = try await harness.host.fetch("github.pr_diff", ["repo": "acme/api", "number": 1])
        }
        // Readers don't need it.
        #expect(try await harness.tool("github_get_diff").run(["repo": "acme/api", "number": 1])["fetched"] == false)
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
        #expect(pulls.count == 9 && Set(pulls.map(\.uid)).count == 9)
        #expect(pulls.allSatisfy { $0.headSHA.count == 40 && !$0.title.isEmpty && $0.url.hasPrefix("https://github.com/") })
        #expect(pulls.contains { $0.isDraft } && pulls.contains { $0.isMine } && pulls.contains { $0.reviewRequested })
        // Each review belongs to a sample PR, at its head commit.
        for review in reviews {
            let pr = pulls.first { $0.uid == review.prUID }
            #expect(pr?.headSHA == review.headSHA)
        }
        let done = reviews.first { $0.prUID == "acme/orders#482" }
        #expect(done?.findings.count == 2 && done?.markdown.contains("| major |") == true)
        let mine = pulls.filter { PullRequestsWidget.matches($0, .init(repo: "", filter: "mine")) }
        #expect(mine.map(\.number) == [479, 805])
        _ = PullRequestsWidget.preview(config: PullRequestsWidget.defaultConfig)
    }
}
