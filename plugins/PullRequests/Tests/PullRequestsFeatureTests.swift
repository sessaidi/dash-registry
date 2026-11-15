import DashKit
import DashKitUI
import Foundation
import SwiftData
import Testing

/// Identity, sync and the automatic review queue, on a fake host and a stubbed GitHub.
@MainActor
struct PullRequestsFeatureTests {
    // MARK: Identity

    @Test func identityAndContracts() {
        let feature = PullRequestsFeature(defaults: UserDefaults(suiteName: "pr-\(UUID())")!)
        #expect(feature.id == "pull-requests" && feature.name == "Pull Requests")
        #expect(feature.layer == .feature && feature.requires == ["github"])
        #expect(feature.metadata.category == .sourceControl && feature.metadata.author == .dash)
        #expect(feature.models.map { String(describing: $0) } == ["PullRequest", "PRReview", "PRDiscussion"])
        #expect(feature.widgets.map(\.kind) == ["github.pulls"])
        #expect(feature.tools.map(\.name) == [
            "github_list_prs", "github_get_pr", "github_get_diff", "github_rerun_review", "github_create_pr",
        ])
        #expect(feature.tools.filter(\.requiresApproval).map(\.name) == ["github_create_pr"])
    }

    @Test func pluginEntryPoint() {
        #expect(PullRequestsPlugin.makeExtensions().map(\.id) == ["pull-requests"])
    }

    @Test func preferencesKeepTheBuiltInKeys() {
        let suite = "pr-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = PullRequestsFeature(defaults: defaults)
        #expect(fresh.pollMinutes == 2 && fresh.autoReview && !fresh.reviewDrafts && fresh.reviewInstructions.isEmpty)
        fresh.pollMinutes = 5
        fresh.autoReview = false
        fresh.reviewDrafts = true
        fresh.reviewInstructions = "Flag unchecked errors."
        #expect(defaults.integer(forKey: "pull-requests.poll") == 5)
        #expect(defaults.object(forKey: "pull-requests.autoReview") as? Bool == false)
        #expect(defaults.object(forKey: "pull-requests.reviewDrafts") as? Bool == true)
        #expect(defaults.string(forKey: "pull-requests.reviewInstructions") == "Flag unchecked errors.")
        let reloaded = PullRequestsFeature(defaults: defaults)
        #expect(reloaded.pollMinutes == 5 && !reloaded.autoReview && reloaded.reviewDrafts && reloaded.reviewInstructions == "Flag unchecked errors.")
    }

    @Test func readsTheGitHubIntegrationThroughExports() {
        let harness = Harness(repos: ["acme/api", "acme/web"], login: "octocat")
        #expect(harness.feature.github?.id == "github")
        #expect(harness.feature.repos == ["acme/api", "acme/web"])
        #expect(harness.feature.viewer == "octocat")
        harness.github.isConnected = false
        #expect(throws: ToolError.self) { _ = try harness.feature.client }
    }

    // MARK: Sync

    @Test func syncStoresOpenPullsAndEmitsActivity() async throws {
        let harness = Harness(autoReview: false)
        harness.serve(["/repos/acme/api/pulls": .json(Fixtures.list(
            Fixtures.pull(1, sha: "a1", author: "me"),
            Fixtures.pull(2, sha: "b1", requested: ["me"], title: "Add retries")), etag: "e1")])
        await harness.feature.sync()
        #expect(harness.feature.lastError == nil && harness.feature.lastSync != nil)

        let pulls = harness.pulls()
        #expect(pulls.map(\.uid) == ["acme/api#1", "acme/api#2"])
        #expect(pulls[0].isMine && !pulls[0].reviewRequested)
        #expect(!pulls[1].isMine && pulls[1].reviewRequested && pulls[1].title == "Add retries")
        #expect(pulls[1].headRef == "feature-2" && pulls[1].baseRef == "main" && pulls[1].headSHA == "b1")
        #expect(pulls[1].updatedAt == ISO8601DateFormatter.date("2026-11-10T09:30:00Z"))
        let opened = harness.host.activity.events.filter { $0.kind == "pr.opened" }
        #expect(opened.count == 2 && opened.allSatisfy { $0.source == "pull-requests" })
        #expect(opened.first { $0.title.contains("#2") }?.importance == .notable)
        #expect(harness.reviews().isEmpty)
    }

    @Test func secondSyncSendsTheETagAndSkipsUnchangedRepos() async throws {
        let harness = Harness(autoReview: false)
        harness.serve(["/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1")), etag: "e1")])
        await harness.feature.sync()
        StubProtocol.serve(harness.apiHost) { request in
            request.value(forHTTPHeaderField: "If-None-Match") == "e1" ? StubProtocol.Reply(status: 304) : .json("[]")
        }
        await harness.feature.sync()
        #expect(harness.feature.lastError == nil)
        #expect(harness.pulls().map(\.uid) == ["acme/api#1"])
        #expect(harness.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "e1")
    }

    @Test func pushesClosuresAndUnwatchedRepos() async throws {
        let harness = Harness(autoReview: false)
        harness.serve(["/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1"), Fixtures.pull(2, sha: "b1")))])
        await harness.feature.sync()
        harness.host.context.insert(PullRequest(uid: "old/repo#9", repo: "old/repo", number: 9))
        harness.serve(["/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a2")))])
        await harness.feature.sync()

        #expect(harness.pulls().map(\.uid) == ["acme/api#1"])
        #expect(harness.pulls().first?.headSHA == "a2")
        let kinds = harness.host.activity.events.map(\.kind)
        #expect(kinds.filter { $0 == "pr.updated" }.count == 1 && kinds.filter { $0 == "pr.closed" }.count == 1)
    }

    @Test func syncFailureIsReported() async throws {
        let harness = Harness()
        harness.serve(["/repos/acme/api/pulls": .json(#"{"message":"Not Found"}"#, status: 404)])
        await harness.feature.sync()
        #expect(harness.feature.lastError?.contains("404") == true)
        await #expect(throws: ToolError.self) { try await harness.feature.prepare(host: harness.host) }
    }

    @Test func fetchesTheViewerWhenTheIntegrationDoesNotExportIt() async throws {
        let harness = Harness(login: "", autoReview: false)
        harness.serve([
            "/user": .json(#"{"login":"me"}"#),
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1", author: "me"))),
        ])
        await harness.feature.sync()
        #expect(harness.feature.viewer == "me")
        #expect(harness.pulls().first?.isMine == true)
    }

    // MARK: Reviews

    @Test func newPullsAreReviewedAutomatically() async throws {
        let harness = Harness()
        harness.feature.reviewInstructions = "We use Go."
        harness.dashii.reply = Fixtures.review
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "abc1234567"), Fixtures.pull(2, sha: "d1", draft: true))),
            "/repos/acme/api/pulls/1": .text("diff --git a/Sources/Fetcher.swift b/Sources/Fetcher.swift\n+retry()\n"),
        ])
        await harness.feature.sync()
        await harness.feature.reviewsFinished()

        // Drafts are skipped unless reviewDrafts is on.
        let review = try #require(harness.feature.latestReview("acme/api#1"))
        #expect(harness.feature.latestReview("acme/api#2") == nil)
        #expect(review.uid == "acme/api#1@abc1234567" && review.model == DashiiModel.strong.rawValue)
        #expect(review.status == "done" && review.verdict == "request_changes" && review.risk == "high")
        #expect(review.summary == "Adds retries; 4xx responses are retried too.")
        #expect(review.testing == "No test for the give-up path.")
        #expect(review.findings.count == 2 && review.findings[0].line == 58 && review.findings[1].suggestion.isEmpty)

        let call = try #require(harness.dashii.calls.first)
        #expect(harness.dashii.calls.count == 1)
        // The AI tab's defaults for reviews: Opus at high effort.
        #expect(call.effort == "high" && call.model == DashiiModel.strong.rawValue && call.outputSchema == PullRequestsFeature.reviewSchema)
        #expect(call.system.hasSuffix("The user's review instructions:\nWe use Go."))
        #expect(call.prompt.contains("Repository: acme/api\nPR #1: PR 1\nAuthor: octocat\nBranch: feature-1 → main"))
        #expect(call.prompt.contains("<diff>\ndiff --git a/Sources/Fetcher.swift b/Sources/Fetcher.swift\n+retry()\n\n</diff>"))
        #expect(!call.prompt.contains("NOTE:"))

        let completed = try #require(harness.host.activity.events.first { $0.kind == "review.completed" })
        #expect(completed.importance == .critical && completed.detail == "request changes, high risk, 2 findings")
    }

    @Test func draftsAreReviewedWhenAskedFor() async throws {
        let harness = Harness()
        harness.feature.reviewDrafts = true
        harness.dashii.reply = #"{"verdict":"approve","risk":"low","summary":"Fine.","testing":"","findings":[]}"#
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(2, sha: "d1", draft: true))),
            "/repos/acme/api/pulls/2": .text("+x\n"),
        ])
        await harness.feature.sync()
        await harness.feature.reviewsFinished()
        let review = try #require(harness.feature.latestReview("acme/api#2"))
        #expect(review.status == "done" && review.verdict == "approve" && review.findings.isEmpty)
        #expect(harness.host.activity.events.first { $0.kind == "review.completed" }?.importance == .notable)
    }

    @Test func hugeDiffsAreCutAndMarkedPartial() async throws {
        let harness = Harness()
        harness.dashii.reply = Fixtures.review
        let diff = String(repeating: "+", count: 600_010)
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1"))),
            "/repos/acme/api/pulls/1": .text(diff),
        ])
        await harness.feature.sync()
        await harness.feature.reviewsFinished()
        let prompt = try #require(harness.dashii.calls.first?.prompt)
        #expect(prompt.contains("NOTE: the diff is 600010 characters; only the first 600000 are included."))
        #expect(!prompt.contains(String(repeating: "+", count: 600_001)))
    }

    @Test func failedReviewsKeepTheError() async throws {
        let harness = Harness()
        harness.dashii.error = ToolError("Dashii is overloaded")
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1"))),
            "/repos/acme/api/pulls/1": .text("+x\n"),
        ])
        await harness.feature.sync()
        await harness.feature.reviewsFinished()
        let review = try #require(harness.feature.latestReview("acme/api#1"))
        #expect(review.status == "failed" && review.error == "Dashii is overloaded")
        #expect(harness.host.activity.events.contains { $0.kind == "review.failed" && $0.detail == "Dashii is overloaded" })
    }

    @Test func malformedReviewOutputFails() async throws {
        let harness = Harness()
        harness.dashii.reply = "Sure! Here is my review."
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1"))),
            "/repos/acme/api/pulls/1": .text("+x\n"),
        ])
        await harness.feature.sync()
        await harness.feature.reviewsFinished()
        #expect(harness.feature.latestReview("acme/api#1")?.status == "failed")
    }

    @Test func missingFieldsFallBackToDefaults() async throws {
        let harness = Harness()
        harness.dashii.reply = #"{"findings":[{"file":"a.swift"}]}"#
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1"))),
            "/repos/acme/api/pulls/1": .text("+x\n"),
        ])
        await harness.feature.sync()
        await harness.feature.reviewsFinished()
        let review = try #require(harness.feature.latestReview("acme/api#1"))
        #expect(review.status == "done" && review.verdict == "comment" && review.risk == "medium" && review.findings.isEmpty)
    }

    @Test func rerunReplacesAFinishedReviewOfTheSameCommit() async throws {
        let harness = Harness()
        harness.dashii.reply = Fixtures.review
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1"))),
            "/repos/acme/api/pulls/1": .text("+x\n"),
        ])
        await harness.feature.sync()
        await harness.feature.reviewsFinished()
        let pr = try #require(harness.feature.pull("acme/api#1"))
        harness.feature.requestReview(pr)
        // A second request while one is queued is a no-op.
        harness.feature.requestReview(pr)
        #expect(harness.reviews().count == 1 && harness.reviews().first?.status == "queued")
        await harness.feature.reviewsFinished()
        #expect(harness.reviews().count == 1 && harness.reviews().first?.status == "done")
        #expect(harness.dashii.calls.count == 2)
    }

    @Test func interruptedReviewsResumeOnStart() async throws {
        let harness = Harness(autoReview: false)
        harness.dashii.reply = Fixtures.review
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a1"))),
            "/repos/acme/api/pulls/1": .text("+x\n"),
        ])
        await harness.feature.sync()
        let interrupted = PRReview(prUID: "acme/api#1", headSHA: "a1", model: "claude-test")
        interrupted.status = "running"
        harness.host.context.insert(interrupted)
        try harness.host.context.save()

        // A relaunch: start() puts the running review back in the queue.
        harness.feature.start(host: harness.host)
        defer { harness.feature.stop() }
        #expect(harness.feature.reviewQueue == ["acme/api#1"])
        await harness.feature.reviewsFinished()
        #expect(harness.feature.latestReview("acme/api#1")?.status == "done")
        #expect(harness.dashii.calls.count == 1)
    }

    @Test func reviewsNeverTouchGitHub() async throws {
        let harness = Harness()
        harness.dashii.reply = Fixtures.review
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "abc1234567"))),
            "/repos/acme/api/pulls/1": .text("+x\n"),
        ])
        await harness.feature.sync()
        await harness.feature.reviewsFinished()
        #expect(harness.feature.latestReview("acme/api#1")?.status == "done")
        // Only reads went to GitHub.
        #expect(harness.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
    }
}
