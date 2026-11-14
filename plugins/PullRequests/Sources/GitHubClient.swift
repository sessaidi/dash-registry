import DashKit
import DashKitUI
import Foundation

/// GitHub REST client over the `github` integration's connection (auth added by the integration).
struct GitHubClient: Sendable {
    let connection: IntegrationConnection

    init(connection: IntegrationConnection) {
        self.connection = connection
    }

    /// Unauthenticated public API access (lower rate limit, public repositories only).
    static var anonymous: GitHubClient {
        GitHubClient(connection: IntegrationConnection(baseURL: URL(string: "https://api.github.com")!))
    }

    struct Response: Sendable {
        let json: JSONValue
        let etag: String?
        let notModified: Bool
    }

    private func request(_ path: String, method: String = "GET", body: JSONValue? = nil, accept: String = "application/vnd.github+json", etag: String? = nil) throws -> URLRequest {
        var headers = ["Accept": accept, "X-GitHub-Api-Version": "2022-11-28"]
        if let etag { headers["If-None-Match"] = etag }
        guard let url = connection.url(path) else { throw ToolError("Bad GitHub path \(path)") }
        return try HTTP.request(url, method: method, body: body, headers: headers)
    }

    /// GET with conditional request support: a 304 costs no rate limit.
    func get(_ path: String, etag: String? = nil) async throws -> Response {
        let (data, response) = try await connection.send(try request(path, etag: etag), service: "GitHub")
        if response.statusCode == 304 { return Response(json: .null, etag: etag, notModified: true) }
        return Response(json: try JSONValue.parse(data), etag: response.value(forHTTPHeaderField: "ETag"), notModified: false)
    }

    func send(_ path: String, method: String, body: JSONValue? = nil) async throws -> JSONValue {
        let (data, _) = try await connection.send(try request(path, method: method, body: body), service: "GitHub")
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    func viewer() async throws -> String {
        try await get("/user").json["login"]?.string ?? ""
    }

    func openPulls(_ repo: String, etag: String?) async throws -> Response {
        try await get("/repos/\(repo)/pulls?state=open&per_page=100&sort=updated&direction=desc", etag: etag)
    }

    func pull(_ repo: String, _ number: Int) async throws -> JSONValue {
        try await get("/repos/\(repo)/pulls/\(number)").json
    }

    func diff(_ repo: String, _ number: Int) async throws -> String {
        let (data, _) = try await connection.send(try request("/repos/\(repo)/pulls/\(number)", accept: "application/vnd.github.diff"), service: "GitHub")
        return String(decoding: data, as: UTF8.self)
    }

    func files(_ repo: String, _ number: Int) async throws -> [JSONValue] {
        try await get("/repos/\(repo)/pulls/\(number)/files?per_page=100").json.array ?? []
    }

    func reviews(_ repo: String, _ number: Int) async throws -> [JSONValue] {
        try await get("/repos/\(repo)/pulls/\(number)/reviews?per_page=100").json.array ?? []
    }

    func comments(_ repo: String, _ number: Int) async throws -> [JSONValue] {
        try await get("/repos/\(repo)/issues/\(number)/comments?per_page=50").json.array ?? []
    }

    func comment(_ repo: String, _ number: Int, body: String) async throws {
        _ = try await send("/repos/\(repo)/issues/\(number)/comments", method: "POST", body: ["body": .string(body)])
    }

    /// `event` is APPROVE, REQUEST_CHANGES or COMMENT.
    func submitReview(_ repo: String, _ number: Int, event: String, body: String) async throws {
        _ = try await send("/repos/\(repo)/pulls/\(number)/reviews", method: "POST", body: ["event": .string(event), "body": .string(body)])
    }

    func merge(_ repo: String, _ number: Int, method: String) async throws {
        _ = try await send("/repos/\(repo)/pulls/\(number)/merge", method: "PUT", body: ["merge_method": .string(method)])
    }

    func createPull(_ repo: String, title: String, head: String, base: String, body: String, draft: Bool) async throws -> JSONValue {
        try await send("/repos/\(repo)/pulls", method: "POST", body: [
            "title": .string(title), "head": .string(head), "base": .string(base), "body": .string(body), "draft": .bool(draft),
        ])
    }

    /// A file's bytes at a ref, via the contents API.
    func file(_ repo: String, path: String, ref: String) async throws -> Data {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let json = try await get("/repos/\(repo)/contents/\(encoded)?ref=\(ref)").json
        guard let content = json["content"]?.string, let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            throw ToolError("\(path) is not a file in \(repo)@\(ref).")
        }
        return data
    }

    /// The commit SHA a branch, tag or SHA points to.
    func resolve(_ repo: String, ref: String) async throws -> String {
        guard let sha = try await get("/repos/\(repo)/commits/\(ref)").json["sha"]?.string else { throw ToolError("Unknown ref \(ref) in \(repo).") }
        return sha
    }

    func defaultBranch(_ repo: String) async throws -> String {
        try await get("/repos/\(repo)").json["default_branch"]?.string ?? "main"
    }
}
