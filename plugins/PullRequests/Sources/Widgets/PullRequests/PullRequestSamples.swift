import DashKit
import Foundation

/// Sample PRs and reviews for the widget gallery. Models are created outside any store,
/// so drawing them never touches the user's data or the network.
@MainActor
enum PullRequestSamples {
    static let viewer = "you"

    static func pulls(now: Date = .now) -> [PullRequest] {
        func pull(_ repo: String, _ number: Int, title: String, author: String, head: String, minutesAgo: Double,
                  draft: Bool = false, requested: Bool = false, ageDays: Double = 1, body: String? = nil,
                  approvals: Int = 0, changes: Int = 0, feedbackFrom: String = "") -> PullRequest {
            let pr = PullRequest(uid: PullRequest.uid(repo, number), repo: repo, number: number)
            pr.apply([
                "title": .string(title), "user": ["login": .string(author)], "html_url": .string("https://github.com/\(repo)/pull/\(number)"),
                "head": ["sha": .string(sha(repo, number)), "ref": .string(head)], "base": ["ref": "main"], "draft": .bool(draft),
                "created_at": .string(now.addingTimeInterval(-minutesAgo * 60 - ageDays * 86_400).formatted(.iso8601)),
                "updated_at": .string(now.addingTimeInterval(-minutesAgo * 60).formatted(.iso8601)),
                "requested_reviewers": .array(requested ? [["login": .string(viewer)]] : []),
                "body": .string(body ?? "Retries transient failures with exponential backoff."),
            ], viewer: viewer)
            pr.approvals = approvals
            pr.changesRequested = changes
            pr.feedbackFrom = feedbackFrom
            return pr
        }
        // Four waiting on the user, two of theirs (one with feedback), three from others.
        return [
            pull("acme/orders", 482, title: "Retry order fetches with exponential backoff", author: "mchen", head: "retry-backoff",
                 minutesAgo: 12, requested: true, ageDays: 0.2),
            pull("acme/api", 812, title: "Add idempotency keys to the payments webhook", author: "jrivera", head: "webhook-idempotency",
                 minutesAgo: 40, requested: true, ageDays: 2,
                 body: "Stores the `Idempotency-Key` header for 24 h and replays the first response for duplicates."),
            pull("acme/web", 1211, title: "Lazy-load product images below the fold", author: "priya", head: "lazy-images",
                 minutesAgo: 180, requested: true, ageDays: 1, body: "Cuts the product page's initial transfer by about 40%."),
            pull("acme/infra", 97, title: "Bump Postgres to 16.4 on staging", author: "lchen", head: "pg-16-4",
                 minutesAgo: 1_560, requested: true, ageDays: 3, body: "Staging only. Production follows next week."),
            pull("acme/orders", 479, title: "Move tax rounding into the pricing service", author: viewer, head: "tax-rounding", minutesAgo: 95,
                 approvals: 1, feedbackFrom: "mchen"),
            pull("acme/api", 805, title: "Paginate the admin audit log endpoint", author: viewer, head: "audit-pagination",
                 minutesAgo: 300, ageDays: 2, body: "Adds cursor pagination; the old `limit` parameter keeps working.",
                 changes: 1, feedbackFrom: "jrivera"),
            pull("acme/web", 1207, title: "Checkout: show saved cards first", author: "priya", head: "saved-cards", minutesAgo: 240),
            pull("acme/api", 801, title: "Remove the legacy v1 coupons endpoint", author: "tsato", head: "drop-v1-coupons",
                 minutesAgo: 720, ageDays: 4, body: "Nothing has called `/v1/coupons` for 90 days."),
            pull("acme/web", 1199, title: "WIP: migrate settings page to the new router", author: "dkim", head: "router-settings",
                 minutesAgo: 1_440, draft: true, ageDays: 6),
        ]
    }

    /// Reviews for the sample PRs: every verdict and risk, one running, and none for a few (the draft, the Postgres bump).
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
        let webhook = PRReview(prUID: "acme/api#812", headSHA: sha("acme/api", 812), model: "claude-opus-5-5")
        webhook.status = "done"
        webhook.verdict = "comment"
        webhook.risk = "medium"
        webhook.summary = "Keys are stored per merchant and replayed correctly. The 24 h expiry runs in the request path instead of a sweeper."
        webhook.findings = [
            PRReview.Finding(file: "Sources/Payments/IdempotencyStore.swift", line: 33, severity: "minor", title: "Expiry on the hot path",
                             detail: "Every request deletes expired keys before reading.", suggestion: "Expire keys in the nightly job."),
        ]
        let images = PRReview(prUID: "acme/web#1211", headSHA: sha("acme/web", 1211), model: "claude-opus-5-5")
        images.status = "done"
        images.verdict = "approve"
        images.risk = "low"
        images.summary = "Uses native `loading=\"lazy\"` with a fixed aspect ratio, so the layout doesn't shift."
        let audit = PRReview(prUID: "acme/api#805", headSHA: sha("acme/api", 805), model: "claude-opus-5-5")
        audit.status = "done"
        audit.verdict = "comment"
        audit.risk = "low"
        audit.summary = "Cursor pagination is correct; the cursor isn't signed, so clients can craft one."
        let coupons = PRReview(prUID: "acme/api#801", headSHA: sha("acme/api", 801), model: "claude-opus-5-5")
        coupons.status = "done"
        coupons.verdict = "request_changes"
        coupons.risk = "high"
        coupons.summary = "The mobile app 6.x still links to `/v1/coupons` from its promo banner; removing it breaks redemption there."
        coupons.findings = [
            PRReview.Finding(file: "Sources/Routes/Coupons.swift", line: 12, severity: "major", title: "Still reachable from mobile 6.x",
                             detail: "The promo banner deep link resolves to the v1 route.", suggestion: "Redirect v1 to v2 for one release."),
        ]
        return [backoff, tax, cards, webhook, images, audit, coupons]
    }

    /// A stable, plausible 40-character commit SHA.
    private static func sha(_ repo: String, _ number: Int) -> String {
        String(format: "%08x", number &* 2_654_435_761 & 0xffff_ffff) + String(repeating: "c0ffee", count: 6).prefix(32)
    }
}
