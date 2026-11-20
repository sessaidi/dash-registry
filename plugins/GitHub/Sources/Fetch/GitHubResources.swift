import DashKit
import Foundation
import Ingestor

/// Something Dash can fetch from GitHub and read back: the fetcher `github.<what>` gets it and
/// stores the compact answer; the reader `github_<what>` (same input) returns it with its
/// freshness, or says to fetch first. Most are routes Ingestor fetches and maps itself; a few
/// need code (text, decoding, a shape that depends on the input).
struct GitHubResource {
    enum Source {
        case route(IngestRoute)
        case parts(KeyValuePairs<String, IngestRoute>)
        case load(@MainActor (GitHubIntegration, JSONValue) async throws -> JSONValue)
    }

    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let properties: [String: JSONValue]
    let required: [String]
    /// Answers to a query (filtered lists, search, raw paths): kept a day, then dropped.
    var queryShaped = false
    /// The reader's name when it isn't `github_<what>`.
    var reader: String?
    let source: Source

    var fetcherName: String { "github." + what }
    var readerName: String { reader ?? "github_" + what }
    var kind: String { "github." + what }
}

extension GitHubIntegration {
    /// Everything the GitHub tools used to ask GitHub live, now fetched into Dash and read there.
    var resources: [GitHubResource] {
        let repo = JSONSchema.string("owner/name")
        let number = JSONSchema.integer("Pull request or issue number.")
        let pages: KeyValuePairs<String, IngestParam> = ["per_page": "100"]
        return [
            GitHubResource(what: "whoami", summary: "The signed-in GitHub user and their organizations.", properties: [:], required: [], source: .parts([
                "": IngestRoute("/user", map: IngestMapper(["login": "login", "name": "name"])),
                "organizations": IngestRoute("/user/orgs", query: pages, map: .pluck("login")),
            ])),
            GitHubResource(what: "repo", summary: "A repository: default branch, visibility, language, topics, open issues, last push.",
                           properties: ["repo": repo], required: ["repo"], source: .route(IngestRoute("/repos/{repo}", map: IngestMapper([
                               "name": "full_name", "description": "description", "default_branch": "default_branch", "private": "private",
                               "language": "language", "topics": .path("topics", or: []), "open_issues": "open_issues_count", "pushed": "pushed_at",
                               "archived": "archived",
                           ])))),
            GitHubResource(what: "branches", summary: "A repository's branches with their last commit and protection.",
                           properties: ["repo": repo], required: ["repo"], source: .route(IngestRoute("/repos/{repo}/branches", query: pages, map: IngestMapper([
                               "name": "name", "sha": .prefix("commit.sha", 7), "protected": .path("protected", or: false),
                           ])))),
            GitHubResource(what: "pulls", summary: "Pull requests of a repository: open (default), closed or all, optionally by author or base branch.",
                           properties: ["repo": repo, "state": JSONSchema.string("open, closed or all.", enum: ["open", "closed", "all"]),
                                        "author": JSONSchema.string("Only this author's."), "base": JSONSchema.string("Only into this branch.")],
                           required: ["repo"], queryShaped: true,
                           source: .route(IngestRoute("/repos/{repo}/pulls", query: ["state": .input("state", default: "open"), "base": .input("base"), "per_page": "50"],
                                                      map: Self.pullMapper.with { item, input in
                                                          guard let author = input["author"]?.string?.lowercased() else { return true }
                                                          return item["user"]?["login"]?.string?.lowercased() == author
                                                      }))),
            GitHubResource(what: "pull", summary: "One pull request: description, branches, mergeability, reviewers, labels, size, comment counts.",
                           properties: ["repo": repo, "number": number], required: ["repo", "number"],
                           source: .route(IngestRoute("/repos/{repo}/pulls/{number}", map: Self.pullMapper.adding([
                               "body": "body", "mergeable": "mergeable_state", "additions": "additions", "deletions": "deletions",
                               "changed_files": "changed_files", "commits": "commits", "comments": "comments", "review_comments": "review_comments",
                           ])))),
            GitHubResource(what: "pull_files", summary: "Files a pull request changes, with status and line counts (and patches when small).",
                           properties: ["repo": repo, "number": number, "patches": JSONSchema.boolean("Include each file's patch (default false).")],
                           required: ["repo", "number"],
                           source: .route(IngestRoute("/repos/{repo}/pulls/{number}/files", query: pages, map: Self.fileMapper.adding([
                               "patch": IngestField { file, input in
                                   input["patches"]?.bool == true ? .string(String((file["patch"]?.string ?? "").prefix(8000))) : nil
                               },
                           ])))),
            GitHubResource(what: "pull_reviews", summary: "Human reviews of a pull request (who, approve or changes requested, what they said) and the review comments on its lines.",
                           properties: ["repo": repo, "number": number], required: ["repo", "number"], source: .parts([
                               "reviews": IngestRoute("/repos/{repo}/pulls/{number}/reviews", query: pages, map: IngestMapper([
                                   "by": "user.login", "state": "state", "body": "body", "at": "submitted_at",
                               ])),
                               "line_comments": IngestRoute("/repos/{repo}/pulls/{number}/comments", query: pages, limit: .last(60), map: IngestMapper([
                                   "by": "user.login", "file": "path", "line": "line", "body": "body", "at": "created_at",
                               ])),
                           ])),
            GitHubResource(what: "checks", summary: "CI on a commit, branch or PR head: each check run's status and conclusion, plus the combined commit status.",
                           properties: ["repo": repo, "ref": JSONSchema.string("Commit SHA, branch or tag.")], required: ["repo", "ref"], source: .parts([
                               "checks": IngestRoute("/repos/{repo}/commits/{ref}/check-runs", query: pages, items: "check_runs", map: IngestMapper([
                                   "name": "name", "status": "status", "conclusion": "conclusion", "url": "html_url",
                               ])),
                               "": IngestRoute("/repos/{repo}/commits/{ref}/status", optional: true, map: IngestMapper([
                                   "state": "state", "statuses": .list("statuses", IngestMapper(["context": "context", "state": "state"])),
                               ])),
                           ])),
            GitHubResource(what: "workflow_runs", summary: "Recent GitHub Actions runs, newest first: workflow, branch, event, status and conclusion. Filter by branch or status (e.g. failure).",
                           properties: ["repo": repo, "branch": JSONSchema.string("Only this branch."), "status": JSONSchema.string("e.g. failure, success, in_progress."),
                                        "limit": JSONSchema.integer("How many (default 15).")], required: ["repo"], queryShaped: true,
                           source: .route(IngestRoute("/repos/{repo}/actions/runs", query: ["branch": .input("branch"), "status": .input("status"),
                                                                                             "per_page": .limit("limit", default: 15, max: 50)],
                                                      items: "workflow_runs", map: Self.runMapper))),
            GitHubResource(what: "run_jobs", summary: "The jobs of an Actions run with their conclusion and the steps that failed.",
                           properties: ["repo": repo, "run_id": JSONSchema.integer("Run id from github_workflow_runs.")], required: ["repo", "run_id"],
                           source: .route(IngestRoute("/repos/{repo}/actions/runs/{run_id}/jobs", query: pages, items: "jobs", map: Self.jobMapper))),
            GitHubResource(what: "job_log", summary: "The end of an Actions job's log (where failures are), to see why it failed.",
                           properties: ["repo": repo, "job_id": JSONSchema.integer("Job id from github_run_jobs."), "lines": JSONSchema.integer("Last N lines (default 200).")],
                           required: ["repo", "job_id"], source: .load { github, input in
                               let log = try await github.ingestClient.text(try Self.repoPath(input) + "/actions/jobs/\(input["job_id"]?.int ?? 0)/logs")
                               let lines = log.split(separator: "\n", omittingEmptySubsequences: false)
                               // The end is where failures are: keep it when the log is too big to store.
                               return .string(String(lines.suffix(min(input["lines"]?.int ?? 200, 2000)).joined(separator: "\n").suffix(90_000)))
                           }),
            GitHubResource(what: "commits", summary: "Commits on a branch, optionally touching a path, by an author, since a date.",
                           properties: ["repo": repo, "branch": JSONSchema.string("Branch or SHA (default: the default branch)."), "path": JSONSchema.string("Only commits touching this path."),
                                        "author": JSONSchema.string("GitHub login or email."), "since": JSONSchema.string("ISO date, e.g. 2026-11-01.")],
                           required: ["repo"], queryShaped: true,
                           source: .route(IngestRoute("/repos/{repo}/commits", query: [
                               "sha": .input("branch"), "path": .input("path"), "author": .input("author"),
                               "since": .compute { $0["since"]?.string.map { $0.count == 10 ? $0 + "T00:00:00Z" : $0 } }, "per_page": "30",
                           ], map: Self.commitMapper))),
            GitHubResource(what: "compare", summary: "Compare two refs (base...head): commits ahead and behind, and the files changed.",
                           properties: ["repo": repo, "base": JSONSchema.string("Base ref."), "head": JSONSchema.string("Head ref.")], required: ["repo", "base", "head"],
                           source: .route(IngestRoute("/repos/{repo}/compare/{base}...{head}", map: IngestMapper([
                               "status": "status", "ahead_by": "ahead_by", "behind_by": "behind_by",
                               "commits": .list("commits", Self.commitMapper, limit: .last(50)), "files": .list("files", Self.fileMapper, limit: .first(150)),
                           ])))),
            GitHubResource(what: "file", summary: "A file's content at a ref (default branch when omitted).",
                           properties: ["repo": repo, "path": JSONSchema.string("File path."), "ref": JSONSchema.string("Branch, tag or SHA.")], required: ["repo", "path"],
                           source: .load { github, input in
                               let file = try await github.ingestClient.json(try Self.repoPath(input) + "/contents/\(input["path"]?.string?.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")"
                                                                             + Self.query([("ref", input["ref"]?.string)]))
                               guard let encoded = file["content"]?.string, let data = Data(base64Encoded: encoded.replacingOccurrences(of: "\n", with: "")) else {
                                   throw ToolError("Not a file (or too large for the contents API).")
                               }
                               return ["path": file["path"] ?? .null, "size": file["size"] ?? .null, "content": .string(String(String(decoding: data, as: UTF8.self).prefix(Self.maxToolCharacters)))]
                           }),
            GitHubResource(what: "issues", summary: "Issues of a repository (pull requests left out): open by default, optionally by label or assignee.",
                           properties: ["repo": repo, "state": JSONSchema.string("open, closed or all.", enum: ["open", "closed", "all"]),
                                        "labels": JSONSchema.string("Comma-separated labels."), "assignee": JSONSchema.string("Login.")],
                           required: ["repo"], queryShaped: true,
                           source: .route(IngestRoute("/repos/{repo}/issues", query: ["state": .input("state", default: "open"), "labels": .input("labels"),
                                                                                       "assignee": .input("assignee"), "per_page": "50"],
                                                      map: IngestMapper(["number": "number", "title": "title", "author": "user.login", "state": "state",
                                                                         "labels": "labels[].name", "updated": "updated_at", "url": "html_url"],
                                                                        keep: { issue, _ in issue["pull_request"] == nil })))),
            GitHubResource(what: "releases", summary: "Recent releases and tags: name, tag, date, draft/prerelease, notes.",
                           properties: ["repo": repo], required: ["repo"],
                           source: .route(IngestRoute("/repos/{repo}/releases", query: ["per_page": "15"], map: IngestMapper([
                               "tag": "tag_name", "name": "name", "date": "published_at", "draft": .path("draft", or: false),
                               "prerelease": .path("prerelease", or: false), "notes": .prefix("body", 2000),
                           ])))),
            GitHubResource(what: "search", summary: "Search GitHub: code (e.g. \"retryPolicy repo:org/name\"), issues and pull requests (e.g. \"is:pr is:open review-requested:@me\"), or repositories.",
                           properties: ["kind": JSONSchema.string("What to search.", enum: ["code", "issues", "repositories"]), "query": JSONSchema.string("GitHub search syntax.")],
                           required: ["kind", "query"], queryShaped: true, source: .load { github, input in
                               let kind = input["kind"]?.string ?? "issues"
                               guard let mapper = Self.searchMappers[kind] else { throw ToolError("kind must be code, issues or repositories") }
                               let route = IngestRoute("/search/\(kind)", query: ["q": .input("query", default: ""), "per_page": "30"],
                                                       map: IngestMapper(["total": "total_count", "items": .list("items", mapper)]))
                               return try await github.ingestClient.fetch(route, input: input)
                           }),
            GitHubResource(what: "notifications", summary: "The user's unread GitHub notifications: review requests, mentions, CI (nothing is marked read).",
                           properties: [:], required: [], source: .route(IngestRoute("/notifications", query: ["per_page": "50"], map: IngestMapper([
                               "repo": "repository.full_name", "reason": "reason", "title": "subject.title", "type": "subject.type", "updated": "updated_at",
                           ])))),
            GitHubResource(what: "api", summary: "Any GitHub REST endpoint (GET only), when no other GitHub fetcher fits, e.g. /repos/owner/name/actions/runs?per_page=10. The answer is stored cut to 200 KB.",
                           properties: ["path": JSONSchema.string("Path and query after the API root, starting with /.")], required: ["path"],
                           queryShaped: true, reader: "github_api_read", source: .load { github, input in
                               try await github.ingestClient.json(try GitHubAPI.validatedPath(input["path"]?.string ?? ""))
                           }),
        ]
    }
}

/// What Dash keeps of GitHub's objects.
extension GitHubIntegration {
    nonisolated static var pullMapper: IngestMapper {
        IngestMapper(["number": "number", "title": "title", "author": "user.login", "state": "state", "draft": .path("draft", or: false),
                      "merged": .exists("merged_at"), "head": "head.ref", "base": "base.ref", "updated": "updated_at", "url": "html_url",
                      "labels": "labels[].name", "requested_reviewers": "requested_reviewers[].login"])
    }

    nonisolated static var runMapper: IngestMapper {
        IngestMapper(["id": "id", "workflow": "name", "branch": "head_branch", "sha": .prefix("head_sha", 7), "event": "event",
                      "status": "status", "conclusion": "conclusion", "started": "run_started_at|created_at", "url": "html_url"])
    }

    nonisolated static var jobMapper: IngestMapper {
        IngestMapper(["id": "id", "name": "name", "status": "status", "conclusion": "conclusion", "url": "html_url",
                      "failed_steps": .compute { job in .array((job["steps"]?.array ?? []).filter { $0["conclusion"]?.string == "failure" }.compactMap { $0["name"] }) }])
    }

    nonisolated static var commitMapper: IngestMapper {
        IngestMapper(["sha": .prefix("sha", 7), "author": "author.login|commit.author.name", "date": "commit.author.date", "message": .firstLine("commit.message")])
    }

    nonisolated static var fileMapper: IngestMapper {
        IngestMapper(["file": "filename", "status": "status", "additions": "additions", "deletions": "deletions"])
    }

    nonisolated static var searchMappers: [String: IngestMapper] {
        ["code": IngestMapper(["repo": "repository.full_name", "path": "path", "url": "html_url"]),
         "repositories": IngestMapper(["repo": "full_name", "description": "description", "pushed": "pushed_at"]),
         "issues": IngestMapper(["title": "title", "number": "number", "state": "state", "pr": .exists("pull_request"), "author": "user.login", "url": "html_url"])]
    }
}

extension IngestMapper {
    /// This mapper, keeping only the items `keep` is true for.
    func with(keep: @escaping (JSONValue, JSONValue) -> Bool) -> IngestMapper {
        var mapper = self
        mapper.keep = keep
        return mapper
    }
}
