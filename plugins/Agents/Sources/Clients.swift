import DashKit
import Foundation

/// The slice of Jira the agents need, over the `atlassian` integration's connection.
/// (Dash's own Jira client lives in the app; plugins only reach Jira through the connection.)
struct JiraClient: Sendable {
    let connection: IntegrationConnection
    var site: URL { connection.baseURL }

    static let issueFields = ["summary", "status", "assignee", "reporter", "priority", "issuetype", "updated", "labels", "parent"]

    private func send(_ path: String, query: [URLQueryItem] = []) async throws -> JSONValue {
        var components = URLComponents(url: site.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        let request = try HTTP.request(components.url!, headers: ["Accept": "application/json"])
        let (data, _) = try await connection.send(request, service: "Jira")
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    func browseURL(_ key: String) -> URL { site.appending(path: "browse/\(key)") }

    /// Full issue with description and recent comments as plain text.
    func issueDetail(_ key: String) async throws -> JSONValue {
        let issue = try await send(
            "rest/api/3/issue/\(key)",
            query: [URLQueryItem(name: "fields", value: (Self.issueFields + ["description", "comment"]).joined(separator: ","))])
        let fields = issue["fields"] ?? .null
        let comments: [JSONValue] = (fields["comment"]?["comments"]?.array ?? []).suffix(15).map { comment in
            ["author": .string(comment["author"]?["displayName"]?.string ?? "?"),
             "created": comment["created"] ?? .null,
             "body": .string(Self.plainText(comment["body"]))]
        }
        return [
            "key": .string(key), "summary": .string(fields["summary"]?.string ?? ""),
            "status": .string(fields["status"]?["name"]?.string ?? ""),
            "type": .string(fields["issuetype"]?["name"]?.string ?? ""),
            "priority": .string(fields["priority"]?["name"]?.string ?? ""),
            "assignee": .string(fields["assignee"]?["displayName"]?.string ?? "Unassigned"),
            "reporter": .string(fields["reporter"]?["displayName"]?.string ?? ""),
            "labels": .array((fields["labels"]?.array?.compactMap(\.string) ?? []).map { .string($0) }),
            "parent": .string(fields["parent"]?["key"]?.string ?? ""),
            "url": .string(browseURL(key).absoluteString),
            "description": .string(Self.plainText(fields["description"])),
            "comments": .array(comments),
        ]
    }

    /// Flattens Atlassian Document Format to plain text.
    static func plainText(_ node: JSONValue?) -> String {
        guard let node else { return "" }
        if let text = node.string { return text }
        var output = ""
        func walk(_ node: JSONValue) {
            switch node["type"]?.string {
            case "text": output += node["text"]?.string ?? ""
            case "hardBreak": output += "\n"
            case "mention": output += node["attrs"]?["text"]?.string ?? ""
            case "listItem": output += "• "
            default: break
            }
            for child in node["content"]?.array ?? [] { walk(child) }
            if ["paragraph", "heading", "listItem", "codeBlock", "blockquote"].contains(node["type"]?.string ?? "") { output += "\n" }
        }
        walk(node)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
