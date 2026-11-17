import DashKit
import Foundation
import SwiftData

/// What Dashii can do with pull requests: list, read what Dash fetched (a PR, its diff, a
/// branch's PRs), re-review, save a review in Dash. Opening a PR is the user's (approval, remote).
extension PullRequestsFeature {
    private struct PRInput: Decodable { let repo: String; let number: Int }
    private struct ListInput: Decodable { let repo: String?; let filter: String? }
    private struct SaveReviewInput: Decodable {
        let repo: String
        let number: Int
        let verdict: String
        let risk: String
        let summary: String
        let findings: [PRReview.Finding]?
        let testing: String?
    }
    private struct CreateInput: Decodable { let repo: String; let head: String; let base: String?; let title: String; let body: String; let draft: Bool? }

    var tools: [DashiiTool] {
        let prProperties: [String: JSONValue] = [
            "repo": JSONSchema.string("owner/name"), "number": JSONSchema.integer("PR number"),
        ]
        return [
            DashiiTool(
                name: "github_list_prs",
                description: "List open pull requests on the watched repositories (kept in sync by Dash), each with its latest Dashii review verdict and risk, and when they were synced.",
                properties: [
                    "repo": JSONSchema.string("Optional owner/name filter."),
                    "filter": JSONSchema.string("Optional: review_requested (your review is requested), mine (you authored), or all.", enum: ["review_requested", "mine", "all"]),
                ]
            ) { [weak self] input in
                guard let self, let host else { return [] }
                let request = try input.toolInput(ListInput.self)
                let pulls = (try? host.context.fetch(FetchDescriptor<PullRequest>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
                let syncedAt: JSONValue = lastSync.map { .string($0.formatted(.iso8601)) } ?? .null
                return .array(pulls.filter { pr in
                    (request.repo == nil || pr.repo == request.repo)
                        && (request.filter != "review_requested" || pr.reviewRequested)
                        && (request.filter != "mine" || pr.isMine)
                }.map { pr in
                    let review = latestReview(pr.uid)
                    return ["repo": .string(pr.repo), "number": .number(Double(pr.number)), "title": .string(pr.title),
                            "author": .string(pr.author), "draft": .bool(pr.isDraft), "url": .string(pr.url),
                            "updated": .string(pr.updatedAt.formatted(.iso8601)),
                            "mine": .bool(pr.isMine), "review_requested": .bool(pr.reviewRequested),
                            "approvals": .number(Double(pr.approvals)), "changes_requested": .number(Double(pr.changesRequested)),
                            "branch": .string(pr.headRef),
                            "dashii_review": review.map { ["status": .string($0.status), "verdict": .string($0.verdict), "risk": .string($0.risk)] } ?? .null,
                            "synced_at": syncedAt]
                })
            },
            reader("pr", description: "A pull request as Dash fetched it (data_fetch github.pr): description, changed files, human reviews, recent comments, with synced_at and stale; plus the latest Dashii review with its findings, from Dash.") { feature, repo, number in
                ["dashii_review": feature.latestReview(PullRequest.uid(repo, number))?.json ?? .null]
            },
            reader("pr_diff", description: "A pull request's unified diff as Dash fetched it (data_fetch github.pr_diff), with synced_at and stale. Large diffs are cut at 190,000 characters and marked as truncated."),
            branchPullsReader,
            DashiiTool(
                name: "github_rerun_review",
                description: "Queue a fresh automatic Dashii review of a pull request's current head commit.",
                properties: prProperties, required: ["repo", "number"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(PRInput.self)
                guard let pr = pull(PullRequest.uid(request.repo, request.number)) else { throw ToolError("That PR is not in the watched list.") }
                requestReview(pr)
                return "queued"
            },
            DashiiTool(
                name: "pull_request_save_review",
                description: "Save a review you did in this conversation on the pull request, in Dash only: it shows in the PR's sheet (Overview and Reviews). Nothing is posted to GitHub. Call it once your review is done.",
                properties: prProperties.merging([
                    "verdict": JSONSchema.string("Your verdict.", enum: ["approve", "request_changes", "comment"]),
                    "risk": JSONSchema.string("How risky the change is.", enum: ["low", "medium", "high"]),
                    "summary": JSONSchema.string("What the PR does and your conclusion, in Markdown."),
                    "findings": JSONSchema.array("Issues found, most important first.", of: JSONSchema.object(properties: [
                        "file": JSONSchema.string("Path in the repository."), "line": JSONSchema.integer("Line, 0 if none."),
                        "severity": JSONSchema.string("blocker, major, minor or nit.", enum: ["blocker", "major", "minor", "nit"]),
                        "title": JSONSchema.string("One line."), "detail": JSONSchema.string("Why it matters."),
                        "suggestion": JSONSchema.string("What to change; empty if none."),
                    ], required: ["file", "line", "severity", "title", "detail", "suggestion"])),
                    "testing": JSONSchema.string("How to test it, if worth saying."),
                ]) { $1 },
                required: ["repo", "number", "verdict", "risk", "summary"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(SaveReviewInput.self)
                guard let pr = pull(PullRequest.uid(request.repo, request.number)) else { throw ToolError("That PR is not in the watched list.") }
                let review = saveChatReview(pr, verdict: request.verdict, risk: request.risk, summary: request.summary,
                                            findings: request.findings ?? [], testing: request.testing ?? "")
                return ["saved": true, "review": review.json, "posted_to_github": false]
            },
            DashiiTool(
                name: "github_create_pr",
                description: "Open a pull request from a branch that is already pushed.",
                properties: [
                    "repo": JSONSchema.string("owner/name"), "head": JSONSchema.string("Branch to merge."),
                    "base": JSONSchema.string("Target branch; defaults to the repository's default branch."),
                    "title": JSONSchema.string("PR title."), "body": JSONSchema.string("Markdown description."),
                    "draft": JSONSchema.boolean("Open as draft (default true)."),
                ],
                required: ["repo", "head", "title", "body"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(CreateInput.self)
                let client = try client
                var base = request.base ?? ""
                if base.isEmpty { base = try await client.defaultBranch(request.repo) }
                let pull = try await client.createPull(request.repo, title: request.title, head: request.head, base: base, body: request.body, draft: request.draft ?? true)
                return ["url": pull["html_url"] ?? .null, "number": pull["number"] ?? .null]
            },
        ]
    }

    /// The reader of a fetched resource: same name and input as the old live tool.
    private func reader(_ what: String, description: String,
                        extra: @escaping @MainActor (PullRequestsFeature, String, Int) -> [String: JSONValue] = { _, _, _ in [:] }) -> DashiiTool {
        let resource = resources.first { $0.what == what }!
        return DashiiTool(name: resource.reader, description: description,
                          properties: PullRequestResource.properties, required: PullRequestResource.required) { [weak self] input in
            guard let self else { return nil }
            return try read(resource, input) { extra(self, $0, $1) }
        }
    }
}
