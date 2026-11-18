import DashKit
import Foundation

/// Dashii's Google Cloud tools are the readers of what Dash fetched (`readers`); these calls are
/// the fetchers' own: any GET on googleapis.com, and the projects.
extension GCPIntegration {
    var tools: [DashiiTool] { readers }

    func apiGet(_ address: String) async throws -> JSONValue {
        let connection = try requireConnection()
        guard let url = URL(string: address), connection.allows(url) else {
            throw ToolError("Only https://*.googleapis.com URLs are allowed.")
        }
        // Secret values stay out of the conversation: names and metadata only (gcp_secrets).
        if url.host()?.hasPrefix("secretmanager.") == true, url.path().hasSuffix(":access") {
            throw ToolError("Secret values can't be read; gcp_secrets lists names and metadata.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, _) = try await connection.send(request, service: "Google Cloud")
        let text = String(decoding: data, as: UTF8.self)
        if text.count > Self.responseLimit { return .string(String(text.prefix(Self.responseLimit)) + "\n[truncated]") }
        return (try? JSONValue.parse(data)) ?? .string(text)
    }

    func listProjects() async throws -> JSONValue {
        let connection = try requireConnection()
        var projects: [JSONValue] = []
        var pageToken: String?
        for _ in 0..<20 {
            var components = URLComponents(url: Self.projectsURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "500")]
                + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let (data, _) = try await connection.send(URLRequest(url: components.url!), service: "Google Cloud")
            let page = try JSONValue.parse(data)
            for project in page["projects"]?.array ?? [] {
                projects.append([
                    "projectId": project["projectId"] ?? .null,
                    "name": project["name"] ?? .null,
                    "state": project["lifecycleState"] ?? project["state"] ?? .null,
                ])
            }
            pageToken = page["nextPageToken"]?.string
            if pageToken?.isEmpty ?? true { break }
        }
        return ["projects": .array(projects), "count": .number(Double(projects.count))]
    }
}
