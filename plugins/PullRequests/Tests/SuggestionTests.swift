import DashKit
import Foundation
import SwiftData
import Testing

@MainActor
struct SuggestionTests {
    @Test func waitingReviewsAndFlaggedOwnPRs() throws {
        let harness = Harness(autoReview: false)
        func pr(_ number: Int, requested: Bool = false, mine: Bool = false, draft: Bool = false) -> PullRequest {
            let pr = PullRequest(uid: PullRequest.uid("acme/api", number), repo: "acme/api", number: number)
            pr.reviewRequested = requested
            pr.isMine = mine
            pr.isDraft = draft
            pr.headSHA = "h\(number)"
            pr.updatedAt = .now
            harness.host.context.insert(pr)
            return pr
        }
        _ = pr(1, requested: true)
        _ = pr(2, requested: true, draft: true)
        let mine = pr(3, mine: true)
        let review = PRReview(prUID: mine.uid, headSHA: "h3", model: "opus")
        review.status = "done"
        review.verdict = "request_changes"
        review.risk = "high"
        harness.host.context.insert(review)

        let suggestions = harness.feature.suggestions
        #expect(suggestions.map(\.id) == ["pull-requests.waiting", "pull-requests.mine.acme/api#3"])
        #expect(suggestions[0].title == "acme/api#1 waits for your review" && suggestions[0].priority == .high)
        #expect(suggestions[1].priority == .high)
        #expect(harness.feature.events.map(\.kind).contains("review.completed"))
    }
}
