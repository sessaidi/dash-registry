import DashKit
import Foundation

/// Something Dash can fetch from GitHub and read back: the fetcher `github.<what>` calls the API
/// and stores the compact answer; the reader `github_<what>` (same input) returns it with its
/// freshness, or says to fetch first.
struct GitHubResource {
    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let properties: [String: JSONValue]
    let required: [String]
    /// Answers to a query (filtered lists, search, raw paths): kept a day, then dropped.
    var queryShaped = false
    /// The reader's name when it isn't `github_<what>`.
    var reader: String?
    /// Calls GitHub and returns the compact answer that gets stored.
    let load: @MainActor (GitHubIntegration, JSONValue) async throws -> JSONValue

    var fetcherName: String { "github." + what }
    var readerName: String { reader ?? "github_" + what }
    var kind: String { "github." + what }
}

extension GitHubIntegration {
    /// Everything the GitHub tools used to ask GitHub live, now fetched into Dash and read there.
    var resources: [GitHubResource] {
        let repo = JSONSchema.string("owner/name")
        let number = JSONSchema.integer("Pull request or issue number.")
        func get(_ github: GitHubIntegration, _ path: String) async throws -> JSONValue { try await github.toolAPI.get(path) }
        return [
            GitHubResource(what: "whoami", summary: "The signed-in GitHub user and their organizations.", properties: [:], required: []) { github, _ in
                let me = try await get(github, "/user")
                let orgs = try await get(github, "/user/orgs?per_page=100")
                return ["login": me["login"] ?? .null, "name": me["name"] ?? .null, "organizations": .array((orgs.array ?? []).compactMap { $0["login"] })]
            },
            GitHubResource(what: "repo", summary: "A repository: default branch, visibility, language, topics, open issues, last push.",
                           properties: ["repo": repo], required: ["repo"]) { github, input in
                let r = try await get(github, try Self.repoPath(input))
                return ["name": r["full_name"] ?? .null, "description": r["description"] ?? .null, "default_branch": r["default_branch"] ?? .null,
                        "private": r["private"] ?? .null, "language": r["language"] ?? .null, "topics": r["topics"] ?? [],
                        "open_issues": r["open_issues_count"] ?? .null, "pushed": r["pushed_at"] ?? .null, "archived": r["archived"] ?? .null]
            },
            GitHubResource(what: "branches", summary: "A repository's branches with their last commit and protection.",
                           properties: ["repo": repo], required: ["repo"]) { github, input in
                .array((try await get(github, try Self.repoPath(input) + "/branches?per_page=100").array ?? []).map {
                    ["name": $0["name"] ?? .null, "sha": .string(String(($0["commit"]?["sha"]?.string ?? "").prefix(7))), "protected": $0["protected"] ?? false]
                })
            },
            GitHubResource(what: "pulls", summary: "Pull requests of a repository: open (default), closed or all, optionally by author or base branch.",
                           properties: ["repo": repo, "state": JSONSchema.string("open, closed or all.", enum: ["open", "closed", "all"]),
                                        "author": JSONSchema.string("Only this author's."), "base": JSONSchema.string("Only into this branch.")],
                           required: ["repo"], queryShaped: true) { github, input in
                let path = try Self.repoPath(input) + "/pulls" + Self.query([("state", input["state"]?.string ?? "open"), ("base", input["base"]?.string), ("per_page", "50")])
                let author = input["author"]?.string?.lowercased()
                return .array((try await get(github, path).array ?? []).filter { author == nil || $0["user"]?["login"]?.string?.lowercased() == author }.map(Self.pullSummary))
            },
            GitHubResource(what: "pull", summary: "One pull request: description, branches, mergeability, reviewers, labels, size.",
                           properties: ["repo": repo, "number": number], required: ["repo", "number"]) { github, input in
                let pr = try await get(github, try Self.repoPath(input) + "/pulls/\(input["number"]?.int ?? 0)")
                return Self.pullSummary(pr).merging(["body": pr["body"] ?? .null, "mergeable": pr["mergeable_state"] ?? .null,
                                                     "additions": pr["additions"] ?? .null, "deletions": pr["deletions"] ?? .null,
                                                     "changed_files": pr["changed_files"] ?? .null, "commits": pr["commits"] ?? .null])
            },
            GitHubResource(what: "pull_files", summary: "Files a pull request changes, with status and line counts (and patches when small).",
                           properties: ["repo": repo, "number": number, "patches": JSONSchema.boolean("Include each file's patch (default false).")],
                           required: ["repo", "number"]) { github, input in
                let files = try await get(github, try Self.repoPath(input) + "/pulls/\(input["number"]?.int ?? 0)/files?per_page=100").array ?? []
                return .array(files.map { file in
                    var row: [String: JSONValue] = ["file": file["filename"] ?? .null, "status": file["status"] ?? .null,
                                                    "additions": file["additions"] ?? .null, "deletions": file["deletions"] ?? .null]
                    if input["patches"]?.bool == true { row["patch"] = .string(String((file["patch"]?.string ?? "").prefix(8000))) }
                    return .object(row)
                })
            },
            GitHubResource(what: "pull_reviews", summary: "Human reviews of a pull request (who, approve or changes requested, what they said) and the review comments on its lines.",
                           properties: ["repo": repo, "number": number], required: ["repo", "number"]) { github, input in
                let base = try Self.repoPath(input) + "/pulls/\(input["number"]?.int ?? 0)"
                let reviews = try await get(github, base + "/reviews?per_page=100").array ?? []
                let comments = try await get(github, base + "/comments?per_page=100").array ?? []
                return ["reviews": .array(reviews.map { ["by": Self.user($0["user"]), "state": $0["state"] ?? .null, "body": $0["body"] ?? .null, "at": $0["submitted_at"] ?? .null] }),
                        "line_comments": .array(comments.suffix(60).map { ["by": Self.user($0["user"]), "file": $0["path"] ?? .null, "line": $0["line"] ?? .null,
                                                                          "body": $0["body"] ?? .null, "at": $0["created_at"] ?? .null] })]
            },
            GitHubResource(what: "checks", summary: "CI on a commit, branch or PR head: each check run's status and conclusion, plus the combined commit status.",
                           properties: ["repo": repo, "ref": JSONSchema.string("Commit SHA, branch or tag.")], required: ["repo", "ref"]) { github, input in
                let base = try Self.repoPath(input) + "/commits/\(input["ref"]?.string?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "HEAD")"
                let runs = try await get(github, base + "/check-runs?per_page=100")["check_runs"]?.array ?? []
                let combined = try? await get(github, base + "/status")
                return ["state": combined?["state"] ?? .null,
                        "checks": .array(runs.map { ["name": $0["name"] ?? .null, "status": $0["status"] ?? .null, "conclusion": $0["conclusion"] ?? .null, "url": $0["html_url"] ?? .null] }),
                        "statuses": .array((combined?["statuses"]?.array ?? []).map { ["context": $0["context"] ?? .null, "state": $0["state"] ?? .null] })]
            },
            GitHubResource(what: "workflow_runs", summary: "Recent GitHub Actions runs, newest first: workflow, branch, event, status and conclusion. Filter by branch or status (e.g. failure).",
                           properties: ["repo": repo, "branch": JSONSchema.string("Only this branch."), "status": JSONSchema.string("e.g. failure, success, in_progress."),
                                        "limit": JSONSchema.integer("How many (default 15).")], required: ["repo"], queryShaped: true) { github, input in
                let path = try Self.repoPath(input) + "/actions/runs" + Self.query([("branch", input["branch"]?.string), ("status", input["status"]?.string),
                                                                                       ("per_page", String(min(input["limit"]?.int ?? 15, 50)))])
                return .array((try await get(github, path)["workflow_runs"]?.array ?? []).map(Self.runSummary))
            },
            GitHubResource(what: "run_jobs", summary: "The jobs of an Actions run with their conclusion and the steps that failed.",
                           properties: ["repo": repo, "run_id": JSONSchema.integer("Run id from github_workflow_runs.")], required: ["repo", "run_id"]) { github, input in
                .array((try await get(github, try Self.repoPath(input) + "/actions/runs/\(input["run_id"]?.int ?? 0)/jobs?per_page=100")["jobs"]?.array ?? []).map(Self.jobSummary))
            },
            GitHubResource(what: "job_log", summary: "The end of an Actions job's log (where failures are), to see why it failed.",
                           properties: ["repo": repo, "job_id": JSONSchema.integer("Job id from github_run_jobs."), "lines": JSONSchema.integer("Last N lines (default 200).")],
                           required: ["repo", "job_id"]) { github, input in
                guard let connection = github.connection, let url = connection.url(try Self.repoPath(input) + "/actions/jobs/\(input["job_id"]?.int ?? 0)/logs") else {
                    throw ToolError("GitHub isn't connected.")
                }
                let (data, _) = try await connection.send(URLRequest(url: url), service: "GitHub")
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                // The end is where failures are: keep it when the log is too big to store.
                return .string(String(lines.suffix(min(input["lines"]?.int ?? 200, 2000)).joined(separator: "\n").suffix(90_000)))
            },
            GitHubResource(what: "commits", summary: "Commits on a branch, optionally touching a path, by an author, since a date.",
                           properties: ["repo": repo, "branch": JSONSchema.string("Branch or SHA (default: the default branch)."), "path": JSONSchema.string("Only commits touching this path."),
                                        "author": JSONSchema.string("GitHub login or email."), "since": JSONSchema.string("ISO date, e.g. 2026-11-01.")],
                           required: ["repo"], queryShaped: true) { github, input in
                let path = try Self.repoPath(input) + "/commits" + Self.query([("sha", input["branch"]?.string), ("path", input["path"]?.string),
                                                                                 ("author", input["author"]?.string), ("since", input["since"]?.string.map { $0.count == 10 ? $0 + "T00:00:00Z" : $0 }),
                                                                                 ("per_page", "30")])
                return .array((try await get(github, path).array ?? []).map(Self.commitSummary))
            },
            GitHubResource(what: "compare", summary: "Compare two refs (base...head): commits ahead and behind, and the files changed.",
                           properties: ["repo": repo, "base": JSONSchema.string("Base ref."), "head": JSONSchema.string("Head ref.")], required: ["repo", "base", "head"]) { github, input in
                let c = try await get(github, try Self.repoPath(input) + "/compare/\(input["base"]?.string ?? "")...\(input["head"]?.string ?? "")")
                return ["status": c["status"] ?? .null, "ahead_by": c["ahead_by"] ?? .null, "behind_by": c["behind_by"] ?? .null,
                        "commits": .array((c["commits"]?.array ?? []).suffix(50).map(Self.commitSummary)),
                        "files": .array((c["files"]?.array ?? []).prefix(150).map { ["file": $0["filename"] ?? .null, "status": $0["status"] ?? .null,
                                                                                     "additions": $0["additions"] ?? .null, "deletions": $0["deletions"] ?? .null] })]
            },
            GitHubResource(what: "file", summary: "A file's content at a ref (default branch when omitted).",
                           properties: ["repo": repo, "path": JSONSchema.string("File path."), "ref": JSONSchema.string("Branch, tag or SHA.")], required: ["repo", "path"]) { github, input in
                let file = try await get(github, try Self.repoPath(input) + "/contents/\(input["path"]?.string?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")"
                                         + Self.query([("ref", input["ref"]?.string)]))
                guard let encoded = file["content"]?.string, let data = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) else {
                    throw ToolError("Not a file (or too large for the contents API).")
                }
                return ["path": file["path"] ?? .null, "size": file["size"] ?? .null, "content": .string(String(String(decoding: data, as: UTF8.self).prefix(Self.maxToolCharacters)))]
            },
            GitHubResource(what: "issues", summary: "Issues of a repository (pull requests left out): open by default, optionally by label or assignee.",
                           properties: ["repo": repo, "state": JSONSchema.string("open, closed or all.", enum: ["open", "closed", "all"]),
                                        "labels": JSONSchema.string("Comma-separated labels."), "assignee": JSONSchema.string("Login.")],
                           required: ["repo"], queryShaped: true) { github, input in
                let path = try Self.repoPath(input) + "/issues" + Self.query([("state", input["state"]?.string ?? "open"), ("labels", input["labels"]?.string),
                                                                                ("assignee", input["assignee"]?.string), ("per_page", "50")])
                return .array((try await get(github, path).array ?? []).filter { $0["pull_request"] == nil }.map {
                    ["number": $0["number"] ?? .null, "title": $0["title"] ?? .null, "author": Self.user($0["user"]), "state": $0["state"] ?? .null,
                     "labels": .array(($0["labels"]?.array ?? []).compactMap { $0["name"] }), "updated": $0["updated_at"] ?? .null, "url": $0["html_url"] ?? .null]
                })
            },
            GitHubResource(what: "releases", summary: "Recent releases and tags: name, tag, date, draft/prerelease, notes.",
                           properties: ["repo": repo], required: ["repo"]) { github, input in
                .array((try await get(github, try Self.repoPath(input) + "/releases?per_page=15").array ?? []).map {
                    ["tag": $0["tag_name"] ?? .null, "name": $0["name"] ?? .null, "date": $0["published_at"] ?? .null, "draft": $0["draft"] ?? false,
                     "prerelease": $0["prerelease"] ?? false, "notes": .string(String(($0["body"]?.string ?? "").prefix(2000)))]
                })
            },
            GitHubResource(what: "search", summary: "Search GitHub: code (e.g. \"retryPolicy repo:org/name\"), issues and pull requests (e.g. \"is:pr is:open review-requested:@me\"), or repositories.",
                           properties: ["kind": JSONSchema.string("What to search.", enum: ["code", "issues", "repositories"]), "query": JSONSchema.string("GitHub search syntax.")],
                           required: ["kind", "query"], queryShaped: true) { github, input in
                let kind = input["kind"]?.string ?? "issues"
                guard ["code", "issues", "repositories"].contains(kind) else { throw ToolError("kind must be code, issues or repositories") }
                let result = try await get(github, "/search/\(kind)" + Self.query([("q", input["query"]?.string ?? ""), ("per_page", "30")]))
                let items = result["items"]?.array ?? []
                return ["total": result["total_count"] ?? .null, "items": .array(items.map { item in
                    switch kind {
                    case "code": ["repo": item["repository"]?["full_name"] ?? .null, "path": item["path"] ?? .null, "url": item["html_url"] ?? .null]
                    case "repositories": ["repo": item["full_name"] ?? .null, "description": item["description"] ?? .null, "pushed": item["pushed_at"] ?? .null]
                    default: ["title": item["title"] ?? .null, "number": item["number"] ?? .null, "state": item["state"] ?? .null,
                              "pr": .bool(item["pull_request"] != nil), "author": Self.user(item["user"]), "url": item["html_url"] ?? .null]
                    }
                })]
            },
            GitHubResource(what: "notifications", summary: "The user's unread GitHub notifications: review requests, mentions, CI (nothing is marked read).",
                           properties: [:], required: []) { github, _ in
                .array((try await get(github, "/notifications?per_page=50").array ?? []).map {
                    ["repo": $0["repository"]?["full_name"] ?? .null, "reason": $0["reason"] ?? .null, "title": $0["subject"]?["title"] ?? .null,
                     "type": $0["subject"]?["type"] ?? .null, "updated": $0["updated_at"] ?? .null]
                })
            },
            GitHubResource(what: "api", summary: "Any GitHub REST endpoint (GET only), when no other GitHub fetcher fits, e.g. /repos/owner/name/actions/runs?per_page=10. The answer is stored cut to 200 KB.",
                           properties: ["path": JSONSchema.string("Path and query after the API root, starting with /.")], required: ["path"],
                           queryShaped: true, reader: "github_api_read") { github, input in
                try await github.toolAPI.get(try GitHubAPI.validatedPath(input["path"]?.string ?? ""))
            },
        ]
    }
}
