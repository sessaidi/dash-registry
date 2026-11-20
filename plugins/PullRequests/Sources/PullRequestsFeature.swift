import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
/// Layer 2 on GitHub: open pull requests on the watched repositories, with
/// automatic Claude reviews and review/comment/merge actions.
final class PullRequestsFeature: DashExtension {
    let id = "pull-requests"
    let name = "Pull Requests"
    let systemImage = "arrow.triangle.pull"
    let metadata = ExtensionMetadata(version: "1.17.0", summary: "Open PRs on watched repos with automatic Dashii reviews.", category: .sourceControl, homepage: "https://github.com/sessaidi/dash", minimumDashKit: "2.4.0")
    let requires = ["github"]

    var pollMinutes: Int { didSet { defaults.set(pollMinutes, forKey: "pull-requests.poll") } }
    var autoReview: Bool { didSet { defaults.set(autoReview, forKey: "pull-requests.autoReview") } }
    var reviewDrafts: Bool { didSet { defaults.set(reviewDrafts, forKey: "pull-requests.reviewDrafts") } }
    /// Your house rules and what to focus on; appended to the reviewer prompt.
    var reviewInstructions: String { didSet { defaults.set(reviewInstructions, forKey: "pull-requests.reviewInstructions") } }
    /// The GitHub integration's repositories the user switched off here.
    var excludedRepos: Set<String> { didSet { defaults.set(Array(excludedRepos).sorted(), forKey: "pull-requests.excludedRepos") } }
    /// Repositories watched here that the integration doesn't list ("owner/name").
    var extraRepos: [String] { didSet { defaults.set(extraRepos, forKey: "pull-requests.extraRepos") } }
    /// Which open PRs to keep: review requests to you, yours, everyone else's, drafts.
    var trackRequested: Bool { didSet { defaults.set(trackRequested, forKey: "pull-requests.trackRequested") } }
    var trackMine: Bool { didSet { defaults.set(trackMine, forKey: "pull-requests.trackMine") } }
    var trackOthers: Bool { didSet { defaults.set(trackOthers, forKey: "pull-requests.trackOthers") } }
    var trackDrafts: Bool { didSet { defaults.set(trackDrafts, forKey: "pull-requests.trackDrafts") } }
    /// Fetch reviews on your PRs and announce approvals, change requests and comments.
    var followFeedback: Bool { didSet { defaults.set(followFeedback, forKey: "pull-requests.followFeedback") } }
    /// Which PRs Claude reviews automatically.
    var reviewRequestedPRs: Bool { didSet { defaults.set(reviewRequestedPRs, forKey: "pull-requests.reviewRequested") } }
    var reviewMyPRs: Bool { didSet { defaults.set(reviewMyPRs, forKey: "pull-requests.reviewMine") } }
    var reviewOtherPRs: Bool { didSet { defaults.set(reviewOtherPRs, forKey: "pull-requests.reviewOthers") } }
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    private(set) var reviewQueue: [String] = []

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var reviewer: Task<Void, Never>?
    @ObservationIgnored private var etags: [String: String] = [:]
    /// The clock, for freshness (tests move it).
    @ObservationIgnored var now: () -> Date = { .now }
    private let defaults: UserDefaults

    /// `defaults` is injectable for tests; the keys are the ones the built-in feature used.
    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
        pollMinutes = defaults.object(forKey: "pull-requests.poll") as? Int ?? 2
        autoReview = defaults.object(forKey: "pull-requests.autoReview") as? Bool ?? true
        reviewDrafts = defaults.object(forKey: "pull-requests.reviewDrafts") as? Bool ?? false
        reviewInstructions = defaults.string(forKey: "pull-requests.reviewInstructions") ?? ""
        excludedRepos = Set(defaults.stringArray(forKey: "pull-requests.excludedRepos") ?? [])
        extraRepos = defaults.stringArray(forKey: "pull-requests.extraRepos") ?? []
        func flag(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: "pull-requests.\(key)") as? Bool ?? fallback }
        trackRequested = flag("trackRequested", true)
        trackMine = flag("trackMine", true)
        trackOthers = flag("trackOthers", true)
        trackDrafts = flag("trackDrafts", true)
        followFeedback = flag("followFeedback", true)
        reviewRequestedPRs = flag("reviewRequested", true)
        reviewMyPRs = flag("reviewMine", true)
        reviewOtherPRs = flag("reviewOthers", true)
    }

    var models: [any PersistentModel.Type] { [PullRequest.self, PRReview.self, PRDiscussion.self] }
    var widgets: [WidgetType] { [WidgetType(PullRequestsWidget.self)] }
    func prepare(host: any ExtensionContext) async throws {
        await sync()
        if let lastError { throw ToolError(lastError) }
    }

    func settingsView() -> AnyView { AnyView(PullRequestsSettingsView(pulls: self)) }

    /// The `github` integration this feature builds on (built in or a plugin), found by id.
    var github: (any Integration)? { host?.integration("github") }
    /// The repositories the GitHub integration lists.
    var availableRepos: [String] { github?.exports["repos"]?.array?.compactMap(\.string) ?? [] }
    /// The repositories watched here: the integration's, minus the ones switched off, plus extras.
    var repos: [String] {
        var seen = Set<String>()
        return (availableRepos.filter { !excludedRepos.contains($0) } + extraRepos).filter { seen.insert($0).inserted }
    }

    /// Whether an open PR is kept, by the "what to track" choices.
    func tracks(_ pr: PullRequest) -> Bool {
        if pr.isDraft && !trackDrafts { return false }
        if pr.reviewRequested && trackRequested { return true }
        return pr.isMine ? trackMine : trackOthers
    }

    /// Whether Claude reviews a PR on its own, by the auto-review choices.
    func reviewsAutomatically(_ pr: PullRequest) -> Bool {
        guard autoReview, !pr.isDraft || reviewDrafts else { return false }
        if pr.reviewRequested && reviewRequestedPRs { return true }
        return pr.isMine ? reviewMyPRs : (!pr.reviewRequested && reviewOtherPRs)
    }
    /// The integration's login; an empty export (token not verified yet) falls back to `/user`.
    var viewer: String { github?.exports["login"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? fetchedViewer }
    @ObservationIgnored private var fetchedViewer = ""

    var client: GitHubClient {
        get throws {
            guard let github else { throw ToolError("The GitHub integration is not installed.") }
            guard let connection = github.connection else { throw ToolError("Connect GitHub in Settings › Integrations.") }
            return GitHubClient(connection: connection)
        }
    }

    func start(host: any ExtensionContext) {
        self.host = host
        // Reviews interrupted by a quit go back in the queue.
        for review in (try? host.context.fetch(FetchDescriptor<PRReview>(predicate: #Predicate { $0.status == "running" || $0.status == "queued" }))) ?? [] {
            review.status = "queued"
            enqueue(review.prUID)
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sync()
                try? await Task.sleep(for: .seconds(Double(max(self?.pollMinutes ?? 2, 1)) * 60))
            }
        }
    }

    func stop() {
        poller?.cancel()
        reviewer?.cancel()
    }

    // MARK: Sync

    func sync() async {
        guard let host, !isSyncing, let client = try? client else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            if viewer.isEmpty { fetchedViewer = try await client.viewer() }
            let viewer = self.viewer
            for repo in repos {
                let response = try await client.openPulls(repo, etag: etags[repo])
                // Read after the network call: a plugin installed meanwhile may have replaced the store.
                let context = host.context
                if response.notModified { continue }
                etags[repo] = response.etag
                let items = response.json.array ?? []
                let existing = Dictionary(
                    ((try? context.fetch(FetchDescriptor<PullRequest>(predicate: #Predicate { $0.repo == repo }))) ?? []).map { ($0.uid, $0) },
                    uniquingKeysWith: { first, _ in first })
                var open = Set<String>()
                for item in items {
                    guard let number = item["number"]?.int else { continue }
                    let uid = PullRequest.uid(repo, number)
                    open.insert(uid)
                    let isNew = existing[uid] == nil
                    let pr = existing[uid] ?? PullRequest(uid: uid, repo: repo, number: number)
                    let updatedBefore = pr.updatedAt
                    let headChanged = pr.apply(item, viewer: viewer)
                    // PRs outside "what to track" aren't kept (and are dropped if they were).
                    guard tracks(pr) else {
                        if !isNew { context.delete(pr) }
                        continue
                    }
                    if isNew { context.insert(pr) }
                    if followFeedback, pr.isMine, isNew || pr.updatedAt != updatedBefore || !pr.feedbackChecked {
                        try? await refreshFeedback(pr, client: client, viewer: viewer)
                    }
                    if isNew {
                        host.emit("pr.opened", from: self, title: "New PR \(pr.repo)#\(pr.number): \(pr.title)", detail: "by \(pr.author)",
                                  link: pr.url, importance: pr.reviewRequested ? .notable : .info)
                    } else if headChanged {
                        host.emit("pr.updated", from: self, title: "New commits on \(pr.repo)#\(pr.number)", link: pr.url)
                    }
                    if headChanged, reviewsAutomatically(pr) { requestReview(pr) }
                }
                for (uid, pr) in existing where !open.contains(uid) {
                    host.emit("pr.closed", from: self, title: "\(pr.repo)#\(pr.number) was merged or closed", detail: pr.title)
                    context.delete(pr)
                }
            }
            // Repositories that were removed from the watch list.
            let context = host.context
            let watched = Set(repos)
            for pr in (try? context.fetch(FetchDescriptor<PullRequest>())) ?? [] where !watched.contains(pr.repo) { context.delete(pr) }
            try? context.save()
            lastSync = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pull(_ uid: String) -> PullRequest? {
        try? host?.context.fetch(FetchDescriptor<PullRequest>(predicate: #Predicate { $0.uid == uid })).first
    }

    /// A review Dashii did in a chat about the PR, stored next to the automatic ones. Its own
    /// uid (time-stamped), so it never replaces the automatic review of the same commit.
    @discardableResult
    func saveChatReview(_ pr: PullRequest, verdict: String, risk: String, summary: String, findings: [PRReview.Finding], testing: String) -> PRReview {
        let review = PRReview(prUID: pr.uid, headSHA: pr.headSHA, model: PRReview.chatModel)
        review.uid = "\(pr.uid)@\(pr.headSHA)#chat-\(Int(Date.now.timeIntervalSince1970))"
        review.status = "done"
        review.verdict = verdict
        review.risk = risk
        review.summary = summary
        review.findings = findings
        review.testing = testing
        host?.context.insert(review)
        try? host?.context.save()
        host?.emit("pr.reviewed", from: self, title: "Review saved on \(pr.repo)#\(pr.number)", detail: "\(verdict) · risk \(risk)", importance: .info)
        return review
    }

    func latestReview(_ prUID: String) -> PRReview? {
        var descriptor = FetchDescriptor<PRReview>(predicate: #Predicate { $0.prUID == prUID }, sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? host?.context.fetch(descriptor).first
    }

    // MARK: Feedback on your PRs

    /// Reads the PR's reviews: counts reviewers whose latest decision is approve or request
    /// changes, and announces a review newer than the last one seen.
    func refreshFeedback(_ pr: PullRequest, client: GitHubClient, viewer: String) async throws {
        let reviews = try await client.reviews(pr.repo, pr.number)
        var decisions: [String: String] = [:]
        var newest: (user: String, state: String, at: Date)?
        for review in reviews {
            guard let user = review["user"]?["login"]?.string, user != viewer,
                  let state = review["state"]?.string, state != "PENDING" else { continue }
            let at = ISO8601DateFormatter.date(review["submitted_at"]?.string) ?? .distantPast
            // A comment doesn't undo an approval or a change request; a dismissal does.
            if state != "COMMENTED" { decisions[user] = state }
            if newest.map({ at > $0.at }) ?? true { newest = (user, state, at) }
        }
        pr.approvals = decisions.values.filter { $0 == "APPROVED" }.count
        pr.changesRequested = decisions.values.filter { $0 == "CHANGES_REQUESTED" }.count
        if let newest, newest.at > (pr.feedbackAt ?? .distantPast) {
            if pr.feedbackChecked {
                let verb = switch newest.state {
                case "APPROVED": "approved"
                case "CHANGES_REQUESTED": "requested changes on"
                default: "commented on"
                }
                host?.emit("pr.feedback", from: self, title: "\(newest.user) \(verb) your PR \(pr.repo)#\(pr.number)", detail: pr.title,
                           link: pr.url, importance: newest.state == "CHANGES_REQUESTED" ? .critical : .notable)
            }
            pr.feedbackAt = newest.at
            pr.feedbackFrom = newest.user
        }
        pr.feedbackChecked = true
    }

    // MARK: Reviews

    /// Queues a Claude review of the PR's current head commit (replacing an older review of the same commit).
    /// Automatic reviews: model, effort and extra instructions are the user's to choose
    /// (Settings › Features › Pull Requests › AI).
    static let reviewTask = AITask(
        id: "review", title: "PR review",
        summary: "Reviews each new or updated PR's diff and posts findings in Dash's fixed format.",
        models: [.strong, .balanced, .deep, .fast], defaultModel: .strong,
        efforts: [.medium, .high, .xhigh, .max], defaultEffort: .high,
        templates: [AITemplate(
            id: "instructions", title: "Extra review instructions",
            defaultText: "",
            variables: ["repo": "owner/name", "author": "PR author login", "base": "Target branch"],
            multiline: true)])

    var aiTasks: [AITask] { [Self.reviewTask] }

    /// The user's AI choices for reviews.
    var ai: AISettings? { host?.aiSettings(.extension(id), tasks: aiTasks) }

    func requestReview(_ pr: PullRequest) {
        guard let host else { return }
        let uid = "\(pr.uid)@\(pr.headSHA)"
        if let old = try? host.context.fetch(FetchDescriptor<PRReview>(predicate: #Predicate { $0.uid == uid })).first {
            if old.status == "queued" || old.status == "running" { return }
            host.context.delete(old)
            try? host.context.save()
        }
        host.context.insert(PRReview(prUID: pr.uid, headSHA: pr.headSHA, model: ai?.model(Self.reviewTask.id).rawValue ?? host.dashii.model))
        try? host.context.save()
        enqueue(pr.uid)
    }

    /// The AI tab's extra instructions, filled in for this PR (empty when unset).
    func extraInstructions(for pr: PullRequest) -> String {
        let text = ai?.render(Self.reviewTask.id, "instructions", ["repo": pr.repo, "author": pr.author, "base": pr.baseRef]) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "\n\nAdditional instructions:\n\(trimmed)"
    }

    /// Waits until the review queue is empty (tests and callers that need the result).
    func reviewsFinished() async {
        while let reviewer { await reviewer.value }
    }

    private func enqueue(_ prUID: String) {
        if !reviewQueue.contains(prUID) { reviewQueue.append(prUID) }
        guard reviewer == nil else { return }
        reviewer = Task { [weak self] in
            while let self, !Task.isCancelled, !self.reviewQueue.isEmpty {
                let next = self.reviewQueue.removeFirst()
                await self.runReview(next)
            }
            self?.reviewer = nil
        }
    }

    private static let maxDiffCharacters = 600_000

    static let reviewSchema: JSONValue = [
        "type": "object", "additionalProperties": false,
        "required": ["verdict", "risk", "summary", "findings", "testing"],
        "properties": [
            "verdict": ["type": "string", "enum": ["approve", "comment", "request_changes"]],
            "risk": ["type": "string", "enum": ["low", "medium", "high"]],
            "summary": ["type": "string", "description": "Two to four sentences: what the PR does and whether it does it correctly."],
            "testing": ["type": "string", "description": "Whether the change is adequately tested, and which tests are missing."],
            "findings": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["file", "line", "severity", "title", "detail", "suggestion"],
                    "properties": [
                        "file": ["type": "string"],
                        "line": ["type": "integer", "description": "Line in the new version of the file, or 0 if not line-specific."],
                        "severity": ["type": "string", "enum": ["blocker", "major", "minor", "nit"]],
                        "title": ["type": "string"],
                        "detail": ["type": "string", "description": "What is wrong and the concrete failure it causes."],
                        "suggestion": ["type": "string", "description": "How to fix it; empty if obvious."],
                    ],
                ],
            ],
        ],
    ]

    private func runReview(_ prUID: String) async {
        guard let host, let pr = pull(prUID), let review = latestReview(prUID), review.status == "queued" else { return }
        review.status = "running"
        try? host.context.save()
        do {
            let client = try client
            var diff = try await client.diff(pr.repo, pr.number)
            var note = ""
            if diff.count > Self.maxDiffCharacters {
                note = "\nNOTE: the diff is \(diff.count) characters; only the first \(Self.maxDiffCharacters) are included. Say in the summary that the review is partial."
                diff = String(diff.prefix(Self.maxDiffCharacters))
            }
            let system = """
                You review pull requests for a senior engineer. Report only problems that matter: bugs, \
                regressions, security issues, data loss, concurrency errors, broken contracts, and missing tests \
                for changed behaviour. Each finding names the file and line in the new code and the concrete \
                failure it causes. Skip style nits unless they hide a bug. If the PR is sound, say so and return \
                few or no findings. Verdict: request_changes only for blocker or major findings.
                """ + (reviewInstructions.isEmpty ? "" : "\n\nThe user's review instructions:\n\(reviewInstructions)")
                + extraInstructions(for: pr)
            let prompt = """
                Repository: \(pr.repo)
                PR #\(pr.number): \(pr.title)
                Author: \(pr.author)
                Branch: \(pr.headRef) → \(pr.baseRef)

                Description:
                \(pr.body.isEmpty ? "(none)" : pr.body)
                \(note)
                <diff>
                \(diff)
                </diff>
                """
            let settings = ai ?? AISettings(tasks: aiTasks)
            let text = try await host.dashii.complete(task: Self.reviewTask.id, settings: settings, system: system, prompt: prompt,
                                                      outputSchema: Self.reviewSchema)
            let result = try JSONValue.parse(text)
            review.verdict = result["verdict"]?.string ?? "comment"
            review.risk = result["risk"]?.string ?? "medium"
            review.summary = result["summary"]?.string ?? ""
            review.testing = result["testing"]?.string ?? ""
            review.findings = (try? result["findings"]?.decode([PRReview.Finding].self)) ?? []
            review.status = "done"
            host.emit("review.completed", from: self, title: "Dashii reviewed \(pr.repo)#\(pr.number)",
                      detail: "\(review.verdict.replacing("_", with: " ")), \(review.risk) risk, \(review.findings.count) findings",
                      link: pr.url, importance: review.risk == "high" || review.verdict == "request_changes" ? .critical : .notable)
        } catch {
            review.status = "failed"
            host.emit("review.failed", from: self, title: "Review of \(pr.repo)#\(pr.number) failed", detail: error.localizedDescription, importance: .notable)
            review.error = error.localizedDescription
        }
        try? host.context.save()
    }
}
