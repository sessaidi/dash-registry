import DashKit
import Foundation

/// Sample PRs and reviews for the widget gallery. Models are created outside any store,
/// so drawing them never touches the user's data or the network.
@MainActor
enum PullRequestSamples {
    static let viewer = "you"

    static func pulls(now: Date = .now) -> [PullRequest] {
        func pull(_ repo: String, _ number: Int, title: String, author: String, head: String, minutesAgo: Double,
                  draft: Bool = false, requested: Bool = false) -> PullRequest {
            let pr = PullRequest(uid: PullRequest.uid(repo, number), repo: repo, number: number)
            pr.apply([
                "title": .string(title), "user": ["login": .string(author)], "html_url": .string("https://github.com/\(repo)/pull/\(number)"),
                "head": ["sha": .string(sha(repo, number)), "ref": .string(head)], "base": ["ref": "main"], "draft": .bool(draft),
                "created_at": .string(now.addingTimeInterval(-minutesAgo * 60 - 86_400).formatted(.iso8601)),
                "updated_at": .string(now.addingTimeInterval(-minutesAgo * 60).formatted(.iso8601)),
                "requested_reviewers": .array(requested ? [["login": .string(viewer)]] : []),
                "body": "Retries transient failures with exponential backoff.",
            ], viewer: viewer)
            return pr
        }
        return [
            pull("acme/orders", 482, title: "Retry order fetches with exponential backoff", author: "mchen", head: "retry-backoff",
                 minutesAgo: 12, requested: true),
            pull("acme/orders", 479, title: "Move tax rounding into the pricing service", author: viewer, head: "tax-rounding", minutesAgo: 95),
            pull("acme/web", 1207, title: "Checkout: show saved cards first", author: "priya", head: "saved-cards", minutesAgo: 240),
            pull("acme/web", 1199, title: "WIP: migrate settings page to the new router", author: "dkim", head: "router-settings",
                 minutesAgo: 1_440, draft: true),
        ]
    }

    /// One review per sample PR: done (two verdicts), running, and never reviewed for the draft.
    static func reviews() -> [PRReview] {
        let backoff = PRReview(prUID: "acme/orders#482", headSHA: sha("acme/orders", 482), model: "claude-opus-5-5")
        backoff.status = "done"
        backoff.verdict = "request_changes"
        backoff.risk = "high"
        backoff.summary = "Adds a retry loop around the order fetcher. The loop also retries 4xx responses, so a bad request is sent five times and the caller waits up to 31 s before it fails."
        backoff.testing = "No test covers the give-up path or the 4xx case."
        backoff.findings = [
            PRReview.Finding(file: "Sources/Orders/Fetcher.swift", line: 58, severity: "major", title: "Retries non-retryable errors",
                             detail: "`shouldRetry` returns true for every HTTPError, including 400 and 404.",
                             suggestion: "Retry only 429, 5xx and URLError timeouts."),
            PRReview.Finding(file: "Sources/Orders/Fetcher.swift", line: 71, severity: "minor", title: "Cancellation ignored",
                             detail: "`Task.sleep` errors are swallowed with `try?`, so a cancelled fetch keeps retrying.", suggestion: ""),
        ]
        let tax = PRReview(prUID: "acme/orders#479", headSHA: sha("acme/orders", 479), model: "claude-opus-5-5")
        tax.status = "done"
        tax.verdict = "approve"
        tax.risk = "low"
        tax.summary = "Moves rounding into PricingService and covers it with table tests. Behaviour is unchanged."
        let cards = PRReview(prUID: "acme/web#1207", headSHA: sha("acme/web", 1207), model: "claude-opus-5-5")
        cards.status = "running"
        return [backoff, tax, cards]
    }

    /// A stable, plausible 40-character commit SHA.
    private static func sha(_ repo: String, _ number: Int) -> String {
        String(format: "%08x", number &* 2_654_435_761 & 0xffff_ffff) + String(repeating: "c0ffee", count: 6).prefix(32)
    }
}
