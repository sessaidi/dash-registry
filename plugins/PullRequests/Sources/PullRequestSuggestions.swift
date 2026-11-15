import DashKit
import Foundation
import SwiftData

/// Home suggestions from the PRs already synced: nothing here calls GitHub.
extension PullRequestsFeature {
    var suggestions: [Suggestion] {
        guard let context = host?.context else { return [] }
        let pulls = (try? context.fetch(FetchDescriptor<PullRequest>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        var result: [Suggestion] = []

        let waiting = pulls.filter { $0.reviewRequested && !$0.isMine && !$0.isDraft }
        if let first = waiting.first {
            let names = waiting.prefix(3).map { "\($0.repo)#\($0.number)" }.joined(separator: ", ")
            result.append(Suggestion(
                id: "pull-requests.waiting",
                title: waiting.count == 1 ? "\(first.repo)#\(first.number) waits for your review" : "\(waiting.count) PRs wait for your review",
                detail: waiting.count == 1 ? first.title : names,
                icon: "eye", priority: waiting.count >= 3 ? .urgent : .high,
                prompt: "Summarise the PRs waiting for my review (\(names)) with Dashii's verdict and risk for each, and tell me which to review first."))
        }

        for pr in pulls where pr.isMine {
            guard let review = latestReview(pr.uid), review.status == "done", review.headSHA == pr.headSHA,
                  review.verdict == "request_changes" || review.risk == "high" else { continue }
            result.append(Suggestion(
                id: "pull-requests.mine.\(pr.uid)",
                title: "Dashii flagged your PR \(pr.repo)#\(pr.number)",
                detail: review.summary.isEmpty ? pr.title : review.summary,
                icon: "exclamationmark.bubble", priority: review.risk == "high" ? .high : .normal,
                prompt: "Walk me through the findings of Dashii's review of \(pr.repo)#\(pr.number) and how to fix each one."))
        }

        for pr in pulls where pr.isMine && pr.changesRequested > 0 {
            result.append(Suggestion(
                id: "pull-requests.changes.\(pr.uid)",
                title: "Changes requested on \(pr.repo)#\(pr.number)",
                detail: pr.feedbackFrom.isEmpty ? pr.title : "Latest review by \(pr.feedbackFrom) · \(pr.title)",
                icon: "arrow.uturn.backward.circle", priority: .high,
                prompt: "Read the review comments on my PR \(pr.repo)#\(pr.number) (github_get_pr) and list what I need to change.",
                link: URL(string: pr.url)))
        }
        for pr in pulls where pr.isMine && !pr.isDraft && pr.approvals > 0 && pr.changesRequested == 0 {
            result.append(Suggestion(
                id: "pull-requests.approved.\(pr.uid)",
                title: "\(pr.repo)#\(pr.number) is approved",
                detail: pr.title, icon: "checkmark.seal", priority: .normal,
                prompt: "My PR \(pr.repo)#\(pr.number) is approved. Check its CI and conflicts and tell me if it's ready to merge.",
                link: URL(string: pr.url)))
        }

        let failed = pulls.filter { pr in latestReview(pr.uid).map { $0.status == "failed" && $0.headSHA == pr.headSHA } ?? false }
        if !failed.isEmpty {
            result.append(Suggestion(
                id: "pull-requests.failed",
                title: failed.count == 1 ? "Review of \(failed[0].repo)#\(failed[0].number) failed" : "\(failed.count) PR reviews failed",
                detail: "Retry them with github_rerun_review.",
                icon: "arrow.clockwise", priority: .low,
                prompt: "Rerun the failed reviews: " + failed.map { "\($0.repo)#\($0.number)" }.joined(separator: ", ") + "."))
        }

        let stale = pulls.filter { $0.isMine && !$0.isDraft && $0.updatedAt < Date.now.addingTimeInterval(-3 * 86_400) }
        if !stale.isEmpty {
            result.append(Suggestion(
                id: "pull-requests.stale",
                title: stale.count == 1 ? "Your PR \(stale[0].repo)#\(stale[0].number) is idle for 3+ days" : "\(stale.count) of your PRs are idle for 3+ days",
                detail: stale.prefix(3).map { $0.title }.joined(separator: " · "),
                icon: "hourglass", priority: .normal,
                prompt: "Which of my open PRs have stalled, and what does each need to move (reviewers, CI, conflicts)?"))
        }
        return result
    }

    var events: [EventDefinition] {
        [EventDefinition("pr.opened", "A PR appeared on a watched repository."),
         EventDefinition("pr.updated", "A PR got new commits or changes."),
         EventDefinition("pr.closed", "A PR was merged or closed."),
         EventDefinition("pr.feedback", "Someone approved, requested changes on or commented on one of your PRs."),
         EventDefinition("review.completed", "Dashii finished reviewing a PR."),
         EventDefinition("review.failed", "Dashii's review of a PR failed.")]
    }
}
