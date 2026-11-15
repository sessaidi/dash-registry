import DashKit
import Foundation
import SwiftData
import Testing

/// Repository choice, what to follow, which PRs Claude reviews, and feedback on your PRs.
@MainActor
struct SettingsTests {
    @Test func reposAreTheIntegrationsMinusExcludedPlusExtras() {
        let harness = Harness(repos: ["acme/api", "acme/web"])
        harness.feature.excludedRepos = ["acme/web"]
        harness.feature.extraRepos = ["other/tool", "acme/api"]
        #expect(harness.feature.repos == ["acme/api", "other/tool"])
    }

    @Test func keepsOnlyThePRsYouFollow() async {
        let harness = Harness(autoReview: false)
        harness.feature.trackOthers = false
        harness.feature.trackDrafts = false
        harness.serve(["/repos/acme/api/pulls": .json(Fixtures.list(
            Fixtures.pull(1, sha: "a", author: "me"),
            Fixtures.pull(2, sha: "b", requested: ["me"]),
            Fixtures.pull(3, sha: "c"),
            Fixtures.pull(4, sha: "d", author: "me", draft: true)))])
        await harness.feature.sync()
        #expect(harness.pulls().map(\.number) == [1, 2])
    }

    @Test func autoReviewFollowsTheChoices() {
        let feature = Harness(autoReview: true).feature
        feature.reviewOtherPRs = false
        feature.reviewMyPRs = false
        let requested = PullRequest(uid: "a#1", repo: "a", number: 1)
        requested.reviewRequested = true
        let mine = PullRequest(uid: "a#2", repo: "a", number: 2)
        mine.isMine = true
        let other = PullRequest(uid: "a#3", repo: "a", number: 3)
        #expect(feature.reviewsAutomatically(requested))
        #expect(!feature.reviewsAutomatically(mine) && !feature.reviewsAutomatically(other))
        feature.reviewMyPRs = true
        #expect(feature.reviewsAutomatically(mine))
    }

    @Test func countsFeedbackAndAnnouncesOnlyNewReviews() async {
        let harness = Harness(autoReview: false)
        func reviews(_ items: String...) -> StubProtocol.Reply { .json("[" + items.joined(separator: ",") + "]") }
        func review(_ user: String, _ state: String, _ at: String) -> String {
            #"{"user":{"login":"\#(user)"},"state":"\#(state)","submitted_at":"\#(at)"}"#
        }
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a", author: "me"))),
            "/repos/acme/api/pulls/1/reviews": reviews(review("ana", "APPROVED", "2026-11-10T10:00:00Z")),
        ])
        await harness.feature.sync()
        let pr = harness.pulls()[0]
        #expect(pr.approvals == 1 && pr.changesRequested == 0 && pr.feedbackFrom == "ana")
        #expect(!harness.host.activity.events.contains { $0.kind == "pr.feedback" })

        // Bob asks for changes; Ana's later comment keeps her approval.
        harness.serve([
            "/repos/acme/api/pulls": .json(Fixtures.list(Fixtures.pull(1, sha: "a", author: "me", updated: "2026-11-11T09:00:00Z"))),
            "/repos/acme/api/pulls/1/reviews": reviews(
                review("ana", "APPROVED", "2026-11-10T10:00:00Z"),
                review("bob", "CHANGES_REQUESTED", "2026-11-11T08:00:00Z"),
                review("ana", "COMMENTED", "2026-11-11T08:30:00Z")),
        ])
        await harness.feature.sync()
        #expect(pr.approvals == 1 && pr.changesRequested == 1)
        #expect(harness.host.activity.events.filter { $0.kind == "pr.feedback" }.map(\.title) == ["ana commented on your PR acme/api#1"])
        #expect(harness.feature.suggestions.contains { $0.id == "pull-requests.changes.acme/api#1" })
    }
}
