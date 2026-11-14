import DashKit
import Foundation

/// The few GitHub REST calls the integration makes itself, on top of `IntegrationConnection`
/// (which adds the auth headers). Features use `connection` directly.
struct GitHubAPI: Sendable {
    static let service = "GitHub"
    let connection: IntegrationConnection

    func get(_ path: String) async throws -> JSONValue {
        try await connection.get(path, service: Self.service)
    }

    /// The signed-in login (`GET /user`).
    func viewer() async throws -> String {
        try Self.login(from: try await get("/user"))
    }

    /// Reads `login` from a `/user` response.
    static func login(from json: JSONValue) throws -> String {
        guard let login = json["login"]?.string, !login.isEmpty else {
            throw ToolError("GitHub didn't return the signed-in login. Check the API URL.")
        }
        return login
    }

    /// Checks a path for `github_api_get`: relative to the API root, starting with one "/",
    /// with no scheme, host, ".." segment or whitespace.
    static func validatedPath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/") else { throw ToolError("path must start with /") }
        let route = path.split(separator: "?", maxSplits: 1).first ?? ""
        guard !route.hasPrefix("//"), !route.contains("://") else {
            throw ToolError("path must be relative to the API root, not a full URL")
        }
        guard !path.contains(where: { $0.isWhitespace }) else { throw ToolError("path must not contain spaces; percent-encode them") }
        guard !route.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
            throw ToolError("path must not contain . or .. segments")
        }
        return path
    }

    /// "owner/name" entries from the settings text (one per line or comma separated).
    static func parseRepos(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { entry in
                let parts = entry.split(separator: "/", omittingEmptySubsequences: false)
                return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            }
    }
}
