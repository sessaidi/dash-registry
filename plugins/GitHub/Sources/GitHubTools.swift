import DashKit
import Foundation

/// Read-only GitHub tools, one question each, with compact answers (no write ever: Dash doesn't
/// comment, review, push or change anything on GitHub through these).
extension GitHubIntegration {
    // MARK: Compact shapes (tested)

    nonisolated static func user(_ json: JSONValue?) -> JSONValue { json?["login"] ?? .null }

    nonisolated static func pullSummary(_ pr: JSONValue) -> JSONValue {
        ["number": pr["number"] ?? .null, "title": pr["title"] ?? .null, "author": user(pr["user"]),
         "state": pr["state"] ?? .null, "draft": pr["draft"] ?? false, "merged": .bool(pr["merged_at"]?.string != nil),
         "head": pr["head"]?["ref"] ?? .null, "base": pr["base"]?["ref"] ?? .null,
         "updated": pr["updated_at"] ?? .null, "url": pr["html_url"] ?? .null,
         "labels": .array((pr["labels"]?.array ?? []).compactMap { $0["name"] }),
         "requested_reviewers": .array((pr["requested_reviewers"]?.array ?? []).map { user($0) })]
    }

    nonisolated static func runSummary(_ run: JSONValue) -> JSONValue {
        ["id": run["id"] ?? .null, "workflow": run["name"] ?? .null, "branch": run["head_branch"] ?? .null,
         "sha": .string(String((run["head_sha"]?.string ?? "").prefix(7))), "event": run["event"] ?? .null,
         "status": run["status"] ?? .null, "conclusion": run["conclusion"] ?? .null,
         "started": run["run_started_at"] ?? run["created_at"] ?? .null, "url": run["html_url"] ?? .null]
    }

    nonisolated static func jobSummary(_ job: JSONValue) -> JSONValue {
        ["id": job["id"] ?? .null, "name": job["name"] ?? .null, "status": job["status"] ?? .null, "conclusion": job["conclusion"] ?? .null,
         "failed_steps": .array((job["steps"]?.array ?? []).filter { $0["conclusion"]?.string == "failure" }.compactMap { $0["name"] }),
         "url": job["html_url"] ?? .null]
    }

    nonisolated static func commitSummary(_ commit: JSONValue) -> JSONValue {
        ["sha": .string(String((commit["sha"]?.string ?? "").prefix(7))),
         "author": commit["author"]?["login"] ?? commit["commit"]?["author"]?["name"] ?? .null,
         "date": commit["commit"]?["author"]?["date"] ?? .null,
         "message": .string(String((commit["commit"]?["message"]?.string ?? "").split(separator: "\n").first ?? ""))]
    }

    /// "owner/name", checked, for paths.
    nonisolated static func repoPath(_ input: JSONValue) throws -> String {
        guard let repo = input["repo"]?.string, case let parts = repo.split(separator: "/", omittingEmptySubsequences: false), parts.count == 2,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } })
        else { throw ToolError("Give repo as owner/name.") }
        return "/repos/" + repo
    }

    nonisolated static func query(_ pairs: [(String, String?)]) -> String {
        let items = pairs.compactMap { key, value in value.map { "\(key)=\($0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0)" } }
        return items.isEmpty ? "" : "?" + items.joined(separator: "&")
    }

    // MARK: Tools

    var readTools: [DashiiTool] {
        let repo = JSONSchema.string("owner/name")
        let number = JSONSchema.integer("Pull request or issue number.")
        func get(_ path: String) async throws -> JSONValue { try await toolAPI.get(path) }
        return [
            DashiiTool(name: "github_whoami", description: "The signed-in GitHub user and their organizations. Read-only.") { [weak self] _ in
                guard self != nil else { return nil }
                let me = try await get("/user")
                let orgs = try await get("/user/orgs?per_page=100")
                return ["login": me["login"] ?? .null, "name": me["name"] ?? .null, "organizations": .array((orgs.array ?? []).compactMap { $0["login"] })]
            },
            DashiiTool(name: "github_repo", description: "A repository: default branch, visibility, language, topics, open issues, last push. Read-only.",
                       properties: ["repo": repo], required: ["repo"]) { [weak self] input in
                guard self != nil else { return nil }
                let r = try await get(try Self.repoPath(input))
                return ["name": r["full_name"] ?? .null, "description": r["description"] ?? .null, "default_branch": r["default_branch"] ?? .null,
                        "private": r["private"] ?? .null, "language": r["language"] ?? .null, "topics": r["topics"] ?? [],
                        "open_issues": r["open_issues_count"] ?? .null, "pushed": r["pushed_at"] ?? .null, "archived": r["archived"] ?? .null]
            },
            DashiiTool(name: "github_branches", description: "A repository's branches with their last commit and protection. Read-only.",
                       properties: ["repo": repo], required: ["repo"]) { [weak self] input in
                guard self != nil else { return nil }
                return .array((try await get(try Self.repoPath(input) + "/branches?per_page=100").array ?? []).map {
                    ["name": $0["name"] ?? .null, "sha": .string(String(($0["commit"]?["sha"]?.string ?? "").prefix(7))), "protected": $0["protected"] ?? false]
                })
            },
            DashiiTool(name: "github_pulls", description: "Pull requests of a repository: open (default), closed or all, optionally by author or base branch. Read-only.",
                       properties: ["repo": repo, "state": JSONSchema.string("open, closed or all.", enum: ["open", "closed", "all"]),
                                    "author": JSONSchema.string("Only this author's."), "base": JSONSchema.string("Only into this branch.")],
                       required: ["repo"]) { [weak self] input in
                guard self != nil else { return nil }
                let path = try Self.repoPath(input) + "/pulls" + Self.query([("state", input["state"]?.string ?? "open"), ("base", input["base"]?.string), ("per_page", "50")])
                let author = input["author"]?.string?.lowercased()
                return .array((try await get(path).array ?? []).filter { author == nil || $0["user"]?["login"]?.string?.lowercased() == author }.map(Self.pullSummary))
            },
            DashiiTool(name: "github_pull", description: "One pull request: description, branches, mergeability, reviewers, labels, size. Read-only.",
                       properties: ["repo": repo, "number": number], required: ["repo", "number"]) { [weak self] input in
                guard self != nil else { return nil }
                let pr = try await get(try Self.repoPath(input) + "/pulls/\(input["number"]?.int ?? 0)")
                return Self.pullSummary(pr).merging(["body": pr["body"] ?? .null, "mergeable": pr["mergeable_state"] ?? .null,
                                                     "additions": pr["additions"] ?? .null, "deletions": pr["deletions"] ?? .null,
                                                     "changed_files": pr["changed_files"] ?? .null, "commits": pr["commits"] ?? .null])
            },
            DashiiTool(name: "github_pull_files", description: "Files a pull request changes, with status and line counts (and patches when small). Read-only.",
                       properties: ["repo": repo, "number": number, "patches": JSONSchema.boolean("Include each file's patch (default false).")],
                       required: ["repo", "number"]) { [weak self] input in
                guard self != nil else { return nil }
                let files = try await get(try Self.repoPath(input) + "/pulls/\(input["number"]?.int ?? 0)/files?per_page=100").array ?? []
                return .array(files.map { file in
                    var row: [String: JSONValue] = ["file": file["filename"] ?? .null, "status": file["status"] ?? .null,
                                                    "additions": file["additions"] ?? .null, "deletions": file["deletions"] ?? .null]
                    if input["patches"]?.bool == true { row["patch"] = .string(String((file["patch"]?.string ?? "").prefix(8000))) }
                    return .object(row)
                })
            },
            DashiiTool(name: "github_pull_reviews", description: "Human reviews of a pull request (who, approve or changes requested, what they said) and the review comments on its lines. Read-only.",
                       properties: ["repo": repo, "number": number], required: ["repo", "number"]) { [weak self] input in
                guard self != nil else { return nil }
                let base = try Self.repoPath(input) + "/pulls/\(input["number"]?.int ?? 0)"
                let reviews = try await get(base + "/reviews?per_page=100").array ?? []
                let comments = try await get(base + "/comments?per_page=100").array ?? []
                return ["reviews": .array(reviews.map { ["by": Self.user($0["user"]), "state": $0["state"] ?? .null, "body": $0["body"] ?? .null, "at": $0["submitted_at"] ?? .null] }),
                        "line_comments": .array(comments.suffix(60).map { ["by": Self.user($0["user"]), "file": $0["path"] ?? .null, "line": $0["line"] ?? .null,
                                                                          "body": $0["body"] ?? .null, "at": $0["created_at"] ?? .null] })]
            },
            DashiiTool(name: "github_checks", description: "CI on a commit, branch or PR head: each check run's status and conclusion, plus the combined commit status. Read-only.",
                       properties: ["repo": repo, "ref": JSONSchema.string("Commit SHA, branch or tag.")], required: ["repo", "ref"]) { [weak self] input in
                guard self != nil else { return nil }
                let base = try Self.repoPath(input) + "/commits/\(input["ref"]?.string?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "HEAD")"
                let runs = try await get(base + "/check-runs?per_page=100")["check_runs"]?.array ?? []
                let combined = try? await get(base + "/status")
                return ["state": combined?["state"] ?? .null,
                        "checks": .array(runs.map { ["name": $0["name"] ?? .null, "status": $0["status"] ?? .null, "conclusion": $0["conclusion"] ?? .null, "url": $0["html_url"] ?? .null] }),
                        "statuses": .array((combined?["statuses"]?.array ?? []).map { ["context": $0["context"] ?? .null, "state": $0["state"] ?? .null] })]
            },
            DashiiTool(name: "github_workflow_runs", description: "Recent GitHub Actions runs, newest first: workflow, branch, event, status and conclusion. Filter by branch or status (e.g. failure). Read-only.",
                       properties: ["repo": repo, "branch": JSONSchema.string("Only this branch."), "status": JSONSchema.string("e.g. failure, success, in_progress."),
                                    "limit": JSONSchema.integer("How many (default 15).")], required: ["repo"]) { [weak self] input in
                guard self != nil else { return nil }
                let path = try Self.repoPath(input) + "/actions/runs" + Self.query([("branch", input["branch"]?.string), ("status", input["status"]?.string),
                                                                                       ("per_page", String(min(input["limit"]?.int ?? 15, 50)))])
                return .array((try await get(path)["workflow_runs"]?.array ?? []).map(Self.runSummary))
            },
            DashiiTool(name: "github_run_jobs", description: "The jobs of an Actions run with their conclusion and the steps that failed. Read-only.",
                       properties: ["repo": repo, "run_id": JSONSchema.integer("Run id from github_workflow_runs.")], required: ["repo", "run_id"]) { [weak self] input in
                guard self != nil else { return nil }
                return .array((try await get(try Self.repoPath(input) + "/actions/runs/\(input["run_id"]?.int ?? 0)/jobs?per_page=100")["jobs"]?.array ?? []).map(Self.jobSummary))
            },
            DashiiTool(name: "github_job_log", description: "The end of an Actions job's log (where failures are), to see why it failed. Read-only.",
                       properties: ["repo": repo, "job_id": JSONSchema.integer("Job id from github_run_jobs."), "lines": JSONSchema.integer("Last N lines (default 200).")],
                       required: ["repo", "job_id"]) { [weak self] input in
                guard let self else { return nil }
                guard let connection, let url = connection.url(try Self.repoPath(input) + "/actions/jobs/\(input["job_id"]?.int ?? 0)/logs") else { throw ToolError("GitHub isn't connected.") }
                let (data, _) = try await connection.send(URLRequest(url: url), service: "GitHub")
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
                return .string(lines.suffix(min(input["lines"]?.int ?? 200, 2000)).joined(separator: "\n"))
            },
            DashiiTool(name: "github_commits", description: "Commits on a branch, optionally touching a path, by an author, since a date. Read-only.",
                       properties: ["repo": repo, "branch": JSONSchema.string("Branch or SHA (default: the default branch)."), "path": JSONSchema.string("Only commits touching this path."),
                                    "author": JSONSchema.string("GitHub login or email."), "since": JSONSchema.string("ISO date, e.g. 2026-11-01.")], required: ["repo"]) { [weak self] input in
                guard self != nil else { return nil }
                let path = try Self.repoPath(input) + "/commits" + Self.query([("sha", input["branch"]?.string), ("path", input["path"]?.string),
                                                                                 ("author", input["author"]?.string), ("since", input["since"]?.string.map { $0.count == 10 ? $0 + "T00:00:00Z" : $0 }),
                                                                                 ("per_page", "30")])
                return .array((try await get(path).array ?? []).map(Self.commitSummary))
            },
            DashiiTool(name: "github_compare", description: "Compare two refs (base...head): commits ahead and behind, and the files changed. Read-only.",
                       properties: ["repo": repo, "base": JSONSchema.string("Base ref."), "head": JSONSchema.string("Head ref.")], required: ["repo", "base", "head"]) { [weak self] input in
                guard self != nil else { return nil }
                let c = try await get(try Self.repoPath(input) + "/compare/\(input["base"]?.string ?? "")...\(input["head"]?.string ?? "")")
                return ["status": c["status"] ?? .null, "ahead_by": c["ahead_by"] ?? .null, "behind_by": c["behind_by"] ?? .null,
                        "commits": .array((c["commits"]?.array ?? []).suffix(50).map(Self.commitSummary)),
                        "files": .array((c["files"]?.array ?? []).prefix(150).map { ["file": $0["filename"] ?? .null, "status": $0["status"] ?? .null,
                                                                                     "additions": $0["additions"] ?? .null, "deletions": $0["deletions"] ?? .null] })]
            },
            DashiiTool(name: "github_file", description: "A file's content at a ref (default branch when omitted). Read-only.",
                       properties: ["repo": repo, "path": JSONSchema.string("File path."), "ref": JSONSchema.string("Branch, tag or SHA.")], required: ["repo", "path"]) { [weak self] input in
                guard self != nil else { return nil }
                let file = try await get(try Self.repoPath(input) + "/contents/\(input["path"]?.string?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")"
                                         + Self.query([("ref", input["ref"]?.string)]))
                guard let encoded = file["content"]?.string, let data = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) else {
                    throw ToolError("Not a file (or too large for the contents API).")
                }
                return ["path": file["path"] ?? .null, "size": file["size"] ?? .null, "content": .string(String(String(decoding: data, as: UTF8.self).prefix(Self.maxToolCharacters)))]
            },
            DashiiTool(name: "github_issues", description: "Issues of a repository (pull requests left out): open by default, optionally by label or assignee. Read-only.",
                       properties: ["repo": repo, "state": JSONSchema.string("open, closed or all.", enum: ["open", "closed", "all"]),
                                    "labels": JSONSchema.string("Comma-separated labels."), "assignee": JSONSchema.string("Login.")], required: ["repo"]) { [weak self] input in
                guard self != nil else { return nil }
                let path = try Self.repoPath(input) + "/issues" + Self.query([("state", input["state"]?.string ?? "open"), ("labels", input["labels"]?.string),
                                                                                ("assignee", input["assignee"]?.string), ("per_page", "50")])
                return .array((try await get(path).array ?? []).filter { $0["pull_request"] == nil }.map {
                    ["number": $0["number"] ?? .null, "title": $0["title"] ?? .null, "author": Self.user($0["user"]), "state": $0["state"] ?? .null,
                     "labels": .array(($0["labels"]?.array ?? []).compactMap { $0["name"] }), "updated": $0["updated_at"] ?? .null, "url": $0["html_url"] ?? .null]
                })
            },
            DashiiTool(name: "github_releases", description: "Recent releases and tags: name, tag, date, draft/prerelease, notes. Read-only.",
                       properties: ["repo": repo], required: ["repo"]) { [weak self] input in
                guard self != nil else { return nil }
                return .array((try await get(try Self.repoPath(input) + "/releases?per_page=15").array ?? []).map {
                    ["tag": $0["tag_name"] ?? .null, "name": $0["name"] ?? .null, "date": $0["published_at"] ?? .null, "draft": $0["draft"] ?? false,
                     "prerelease": $0["prerelease"] ?? false, "notes": .string(String(($0["body"]?.string ?? "").prefix(2000)))]
                })
            },
            DashiiTool(name: "github_search", description: "Search GitHub: code (e.g. \"retryPolicy repo:org/name\"), issues and pull requests (e.g. \"is:pr is:open review-requested:@me\"), or repositories. Read-only.",
                       properties: ["kind": JSONSchema.string("What to search.", enum: ["code", "issues", "repositories"]), "query": JSONSchema.string("GitHub search syntax.")],
                       required: ["kind", "query"]) { [weak self] input in
                guard self != nil else { return nil }
                let kind = input["kind"]?.string ?? "issues"
                guard ["code", "issues", "repositories"].contains(kind) else { throw ToolError("kind must be code, issues or repositories") }
                let result = try await get("/search/\(kind)" + Self.query([("q", input["query"]?.string ?? ""), ("per_page", "30")]))
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
            DashiiTool(name: "github_notifications", description: "The user's unread GitHub notifications: review requests, mentions, CI. Read-only (nothing is marked read).") { [weak self] _ in
                guard self != nil else { return nil }
                return .array((try await get("/notifications?per_page=50").array ?? []).map {
                    ["repo": $0["repository"]?["full_name"] ?? .null, "reason": $0["reason"] ?? .null, "title": $0["subject"]?["title"] ?? .null,
                     "type": $0["subject"]?["type"] ?? .null, "updated": $0["updated_at"] ?? .null]
                })
            },
        ]
    }
}
