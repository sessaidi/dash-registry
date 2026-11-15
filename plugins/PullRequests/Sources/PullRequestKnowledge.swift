import DashKit
import Foundation
import SwiftData

/// PRs for Dash's knowledge graph: the repository, the author, and the files Claude's review
/// commented on. Ticket keys in the title, body or branch are linked by Dash.
extension PullRequestsFeature {
    var knowledge: [KnowledgeEntity] {
        guard let context = host?.context else { return [] }
        let pulls = (try? context.fetch(FetchDescriptor<PullRequest>())) ?? []
        return pulls.map { pr in
            var links = [KnowledgeLink(to: "repo:\(pr.repo)", kind: "in_repo"),
                         KnowledgeLink(to: "person:\(pr.author)", kind: "authored_by")]
            if let review = latestReview(pr.uid) {
                for file in Set(review.findings.map(\.file)) where !file.isEmpty {
                    links.append(KnowledgeLink(to: "repofile:\(pr.repo):\(file)", kind: "touches"))
                }
            }
            var text = "Branch \(pr.headRef) into \(pr.baseRef). \(pr.isDraft ? "Draft. " : "")\(pr.body)"
            if let review = latestReview(pr.uid), review.status == "done" {
                text += "\n\nDashii's review: \(review.verdict), \(review.risk) risk. \(review.summary)"
            }
            return KnowledgeEntity(id: "pr:\(pr.uid)", kind: "pr", title: "\(pr.uid) \(pr.title)", text: text,
                                   url: URL(string: pr.url), updated: pr.updatedAt, links: links)
        }
    }

    /// PRs opened per day, among the open PRs Dash follows, and Claude reviews per day.
    var activitySeries: [ActivitySeries] {
        [ActivitySeries(id: "opened", title: "PRs opened", unit: "PRs", systemImage: "arrow.triangle.pull") { [weak self] interval in
            let pulls = (try? self?.host?.context.fetch(FetchDescriptor<PullRequest>())) ?? []
            return ActivitySeries.countPerDay(pulls.map(\.createdAt), in: interval)
         },
         ActivitySeries(id: "reviews", title: "Dashii reviews", unit: "reviews", systemImage: "checkmark.seal") { [weak self] interval in
            let reviews = (try? self?.host?.context.fetch(FetchDescriptor<PRReview>())) ?? []
            return ActivitySeries.countPerDay(reviews.filter { $0.status == "done" }.map(\.createdAt), in: interval)
         }]
    }
}
