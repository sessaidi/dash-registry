import DashKit
import Foundation
import SwiftData

/// Pull requests for DashQL: the `prs` dataset (Dash's copy of the watched repos' open PRs, with
/// Claude's latest review) and the Pull Requests widget's query bar.
extension PullRequest {
    static let queryFields: [QueryDataset.Field] = [
        .init("repo", "string", "owner/name"),
        .init("number", "number", "PR number"),
        .init("title", "string", "Title"),
        .init("author", "string", "Author's login", aliases: ["by"]),
        .init("state", "string", "open (Dash keeps open PRs)"),
        .init("draft", "bool", "Draft PR"),
        .init("branch", "string", "Head branch", aliases: ["head"]),
        .init("base", "string", "Target branch"),
        .init("tickets", "list", "Ticket keys in the title or branch (joins jira.key)", aliases: ["ticket"]),
        .init("review_verdict", "string", "Dashii's verdict: approve, comment or request_changes", aliases: ["verdict"]),
        .init("risk", "string", "Dashii's risk: low, medium or high"),
        .init("review_status", "string", "queued, running, done or failed"),
        .init("approvals", "number", "Approving reviews"),
        .init("changes_requested", "number", "Reviews requesting changes"),
        .init("review_requested", "bool", "The user's review is requested"),
        .init("mine", "bool", "The user opened it"),
        .init("created", "date", "Opened"),
        .init("updated", "date", "Last update"),
        .init("url", "string", "Link"),
    ]

    /// Ticket keys (KAN-123) in the title and head branch.
    var ticketKeys: [String] {
        var keys: [String] = []
        for text in [title, headRef] {
            for match in text.uppercased().matches(of: /[A-Z][A-Z0-9]{1,9}-\d+/) where !keys.contains(String(match.output)) {
                keys.append(String(match.output))
            }
        }
        return keys
    }

    func queryRow(review: PRReview?) -> JSONValue {
        [
            "repo": .string(repo), "number": .number(Double(number)), "title": .string(title), "author": .string(author),
            "state": "open", "draft": .bool(isDraft), "branch": .string(headRef), "base": .string(baseRef),
            "tickets": .array(ticketKeys.map(JSONValue.string)),
            "review_verdict": review.map { .string($0.verdict) } ?? .null, "risk": review.map { .string($0.risk) } ?? .null,
            "review_status": review.map { .string($0.status) } ?? .null,
            "approvals": .number(Double(approvals)), "changes_requested": .number(Double(changesRequested)),
            "review_requested": .bool(reviewRequested), "mine": .bool(isMine),
            "created": createdAt.queryValue, "updated": updatedAt.queryValue, "url": .string(url),
        ]
    }
}

extension PullRequestsFeature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "prs", aliases: ["pulls", "pull_requests"], summary: "Open pull requests on the watched repositories, with Dashii's latest review.",
                      fields: PullRequest.queryFields) { [weak self] _ in
            guard let context = self?.host?.context else { return [] }
            let pulls = (try? context.fetch(FetchDescriptor<PullRequest>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
            let reviews = (try? context.fetch(FetchDescriptor<PRReview>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
            let latest = Dictionary(reviews.map { ($0.prUID, $0) }, uniquingKeysWith: { first, _ in first })
            return pulls.map { $0.queryRow(review: latest[$0.uid]) }
        }]
    }
}
