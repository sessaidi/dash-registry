import DashKit
import Foundation

/// Something Dash can fetch about a pull request and read back: the fetcher `github.<what>` calls
/// GitHub and stores the compact answer; the reader (same input) returns it with its freshness, or
/// says to fetch first.
struct PullRequestResource {
    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let reader: String
    /// Calls GitHub and returns the compact answer that gets stored.
    let load: @MainActor (GitHubClient, _ repo: String, _ number: Int) async throws -> JSONValue

    var fetcherName: String { "github." + what }
    var kind: String { "github." + what }
    static let properties: [String: JSONValue] = ["repo": JSONSchema.string("owner/name"), "number": JSONSchema.integer("PR number")]
    static let required = ["repo", "number"]
}

extension PullRequestsFeature {
    /// Diffs are cut here (UTF-8 bytes) so the stored record stays under the 200 KB cap.
    static let diffLimit = 190_000

    /// What `github_get_pr` and `github_get_diff` used to ask GitHub live.
    var resources: [PullRequestResource] {
        [
            PullRequestResource(
                what: "pr", summary: "A pull request: description, state, branches, changed files, human reviews and the last 20 comments.",
                reader: "github_get_pr"
            ) { client, repo, number in
                let pull = try await client.pull(repo, number)
                let files = try await client.files(repo, number)
                let reviews = try await client.reviews(repo, number)
                let comments = try await client.comments(repo, number)
                return [
                    "title": pull["title"] ?? .null, "body": pull["body"] ?? .null, "author": pull["user"]?["login"] ?? .null,
                    "state": pull["state"] ?? .null, "mergeable_state": pull["mergeable_state"] ?? .null,
                    "head": pull["head"]?["ref"] ?? .null, "base": pull["base"]?["ref"] ?? .null,
                    "files": .array(files.map { ["file": $0["filename"] ?? .null, "status": $0["status"] ?? .null, "additions": $0["additions"] ?? .null, "deletions": $0["deletions"] ?? .null] }),
                    "reviews": .array(reviews.map { ["user": $0["user"]?["login"] ?? .null, "state": $0["state"] ?? .null, "body": $0["body"] ?? .null] }),
                    "comments": .array(comments.suffix(20).map { ["user": $0["user"]?["login"] ?? .null, "body": $0["body"] ?? .null] }),
                ]
            },
            PullRequestResource(
                what: "pr_diff", summary: "A pull request's unified diff, cut at 190,000 characters and marked as truncated.",
                reader: "github_get_diff"
            ) { client, repo, number in
                let diff = try await client.diff(repo, number)
                guard diff.utf8.count > Self.diffLimit else { return ["truncated": false, "diff": .string(diff)] }
                var cut = String(decoding: diff.utf8.prefix(Self.diffLimit), as: UTF8.self)
                if cut.utf8.count > Self.diffLimit { cut = String(cut.dropLast()) }
                return ["truncated": true, "total_characters": .number(Double(diff.count)), "diff": .string(cut)]
            },
        ]
    }
}
