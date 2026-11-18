import DashKit
import Foundation

/// Links to Jira tickets on the `atlassian` integration's site (tickets themselves are read from
/// what Dash stored, `jira_issue`).
struct JiraClient: Sendable {
    let connection: IntegrationConnection
    var site: URL { connection.baseURL }

    func browseURL(_ key: String) -> URL { site.appending(path: "browse/\(key)") }
}

/// Opens pull requests over the `github` integration's connection (auth added by the integration).
struct GitHubClient: Sendable {
    let connection: IntegrationConnection

    func createPull(_ repo: String, title: String, head: String, base: String, body: String, draft: Bool) async throws -> JSONValue {
        guard let url = connection.url("/repos/\(repo)/pulls") else { throw ToolError("Bad GitHub path /repos/\(repo)/pulls") }
        let request = try HTTP.request(url, method: "POST", body: [
            "title": .string(title), "head": .string(head), "base": .string(base), "body": .string(body), "draft": .bool(draft),
        ], headers: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"])
        let (data, _) = try await connection.send(request, service: "GitHub")
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }
}
