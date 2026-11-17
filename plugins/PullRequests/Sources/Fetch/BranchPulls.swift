import DashKit
import Foundation

/// The pull requests of a branch, open or not, fetched on request (`github.branch_pulls`) and kept
/// in Dash's mirror: the Agents plugin uses them to tell whether a worktree's PR was merged.
extension PullRequestsFeature {
    static let branchPullsKind = "github.branch_pulls"

    private static let branchProperties: [String: JSONValue] = ["repo": JSONSchema.string("owner/name"), "branch": JSONSchema.string("Branch name.")]

    var branchPullsFetcher: DataFetcher {
        DataFetcher(
            name: "github.branch_pulls",
            summary: "The pull requests (open, closed, merged) whose head is a branch of a repository, stored in Dash's database. Read them with github_branch_pulls, or worktrees_list (Agents).",
            properties: Self.branchProperties, required: ["repo", "branch"]
        ) { [weak self] input in
            guard let self else { throw ToolError("Pull Requests isn't ready.") }
            let (repo, branch) = try Self.branchInput(input)
            return try await branchPulls(repo: repo, branch: branch)
        }
    }

    /// Reads what `github.branch_pulls` stored, with its freshness.
    var branchPullsReader: DashiiTool {
        DashiiTool(
            name: "github_branch_pulls",
            description: "The pull requests (open, closed, merged) of a branch, as Dash fetched them (data_fetch github.branch_pulls), with synced_at and stale.",
            properties: Self.branchProperties, required: ["repo", "branch"]
        ) { [weak self] input in
            guard let self, let host else { throw ToolError("Pull Requests isn't started.") }
            let (repo, branch) = try Self.branchInput(input)
            let refresh: JSONValue = ["fetcher": "github.branch_pulls", "input": ["repo": .string(repo), "branch": .string(branch)]]
            guard let record = host.synced.record(kind: Self.branchPullsKind, scope: repo, key: branch) else {
                return notFetched("github.branch_pulls", input: refresh["input"] ?? [:])
            }
            let freshness = Freshness(syncedAt: record.updatedAt, maxAge: .seconds(Self.freshMinutes * 60), refresh: refresh, now: now())
            return JSONValue.object(["items": record.value["pulls"] ?? []]).merging(freshness.json)
        }
    }

    nonisolated static func branchInput(_ input: JSONValue) throws -> (repo: String, branch: String) {
        let repo = (input["repo"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = (input["branch"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRepo(repo), !branch.isEmpty else { throw ToolError("Give repo as owner/name and a branch.") }
        return (repo, branch)
    }

    /// Stores the branch's pulls. The receipt keeps them in `pulls` (the Agents plugin reads it).
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
        let unchanged = host?.synced.record(kind: Self.branchPullsKind, scope: repo, key: branch)?.value == value
        let syncedAt = now()
        host?.synced.upsert([SyncedRecord(kind: Self.branchPullsKind, scope: repo, key: branch, value: value, source: id, updatedAt: syncedAt)])
        let input: JSONValue = ["repo": .string(repo), "branch": .string(branch)]
        return Self.receipt(stored: unchanged ? 0 : 1, unchanged: unchanged ? 1 : 0, keys: ["\(Self.branchPullsKind)/\(repo)/\(branch)"],
                            syncedAt: syncedAt, readWith: "github_branch_pulls " + input.jsonString())
            .merging(["pulls": value["pulls"] ?? []])
    }
}
