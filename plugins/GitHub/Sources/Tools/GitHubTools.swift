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

    // MARK: Paths (tested)

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
