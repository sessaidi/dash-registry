import DashKit
import Foundation

/// The pull requests of a branch, open or not, fetched on request (`github.branch_pulls`) and kept
/// in Dash's mirror: the Agents plugin uses them to tell whether a worktree's PR was merged.
extension PullRequestsFeature {
    static let branchPullsKind = "github.branch_pulls"

    var fetchers: [DataFetcher] {
        [DataFetcher(
            name: "github.branch_pulls",
            summary: "The pull requests (open, closed, merged) whose head is a branch of a repository, stored in Dash's database. Read them in the answer, or with worktrees_list (Agents).",
            properties: ["repo": JSONSchema.string("owner/name"), "branch": JSONSchema.string("Branch name.")],
            required: ["repo", "branch"]
        ) { [weak self] input in
            guard let self else { throw ToolError("Pull Requests isn't ready.") }
            guard let repo = input["repo"]?.string, repo.split(separator: "/").count == 2, let branch = input["branch"]?.string, !branch.isEmpty else {
                throw ToolError("Give repo as owner/name and a branch.")
            }
            return try await branchPulls(repo: repo, branch: branch)
        }]
    }

    func branchPulls(repo: String, branch: String) async throws -> JSONValue {
        let owner = repo.split(separator: "/")[0]
        let head = "\(owner):\(branch)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let found = try await client.get("/repos/\(repo)/pulls?state=all&head=\(head)&per_page=10").json.array ?? []
        let pulls: [JSONValue] = found.map { pull in
            ["number": pull["number"] ?? .null, "title": pull["title"] ?? .null, "url": pull["html_url"] ?? .null,
             "state": pull["state"] ?? .null, "merged": .bool(pull["merged_at"]?.string != nil), "draft": pull["draft"] ?? false,
             "repo": .string(repo), "branch": .string(branch), "updated": pull["updated_at"] ?? .null]
        }
        let value = Sanitizer.clean(["pulls": .array(pulls)])
        host?.synced.upsert([SyncedRecord(kind: Self.branchPullsKind, scope: repo, key: branch, value: value, source: id)])
        return value.merging(["synced_at": .string(Date.now.formatted(.iso8601)), "read_with": "this answer, or worktrees_list"])
    }
}
