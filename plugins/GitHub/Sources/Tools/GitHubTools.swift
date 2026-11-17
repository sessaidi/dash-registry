import DashKit
import Foundation

/// GitHub's tools, all read-only (Dash doesn't comment, review, push or change anything on GitHub).
/// Dashii and agents get the readers: they answer from what the fetchers stored in Dash. The
/// tools that call GitHub stay for other extensions (`callsService`).
extension GitHubIntegration {
    private struct GetInput: Decodable { let path: String }

    var tools: [DashiiTool] { readers + releaseReaders + extensionTools }

    /// Tools other extensions run by name: Workspaces reads raw paths, Releases syncs its mirror.
    var extensionTools: [DashiiTool] {
        [
            DashiiTool(
                name: "github_api_get",
                description: "Read any GitHub REST endpoint as the user (GET only), e.g. /repos/owner/name/actions/runs?per_page=10. For other extensions; Dashii uses data_fetch github.api. Large responses are cut at 100,000 characters.",
                properties: ["path": JSONSchema.string("Path and query after the API root, starting with /.")], required: ["path"], callsService: true
            ) { [weak self] input in
                guard let self else { return nil }
                let path = try GitHubAPI.validatedPath(try input.toolInput(GetInput.self).path)
                let json = try await toolAPI.get(path)
                let text = json.jsonString()
                return text.count > Self.maxToolCharacters
                    ? ["truncated": true, "json": .string(String(text.prefix(Self.maxToolCharacters)))] : json
            },
        ] + syncTools
    }

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
}
