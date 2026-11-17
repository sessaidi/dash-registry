import DashKit
import Foundation
import SwiftData
import SwiftUI

/// Serves canned responses per host, so parallel tests (each with its own host) don't collide.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var body = Data()
        var headers: [String: String] = ["Content-Type": "application/json"]

        static func json(_ text: String, status: Int = 200, etag: String? = nil) -> Reply {
            var reply = Reply(status: status, body: Data(text.utf8))
            if let etag { reply.headers["ETag"] = etag }
            return reply
        }

        static func text(_ text: String) -> Reply { Reply(body: Data(text.utf8), headers: ["Content-Type": "text/plain"]) }
    }

    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]

    static func serve(_ host: String, _ handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            log[host] = []
        }
    }

    /// Replies keyed by "METHOD /path" or "/path" (any method); unknown routes get a 404.
    static func serve(_ host: String, routes: [String: Reply]) {
        serve(host) { request in
            let path = request.url?.path() ?? ""
            return routes["\(request.httpMethod ?? "GET") \(path)"] ?? routes[path] ?? .json(#"{"message":"Not Found"}"#, status: 404)
        }
    }

    static func requests(_ host: String) -> [URLRequest] { lock.withLock { log[host] ?? [] } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves the body into a stream; keep it readable for assertions.
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = body
        }
        let host = request.url?.host() ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.log[host, default: []].append(request)
            return Self.handlers[host]
        }
        let reply = handler?(request) ?? Reply(status: 599, body: Data("no stub for \(host)".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    var bodyJSON: JSONValue? { httpBody.flatMap { try? JSONValue.parse($0) } }
}

@MainActor
final class FakePermissions: PermissionAsking {
    func ask(_ prompt: PermissionPrompt) async -> Bool { false }
}

/// Answers every review with `reply` (or throws `error`) and records what it was asked.
@MainActor
final class FakeDashii: DashiiService {
    struct Call {
        let system: String
        let prompt: String
        let outputSchema: JSONValue?
        let effort: String?
        var model: String?
    }

    var model: String { "claude-test" }
    var reply = ""
    var error: (any Error)?
    private(set) var calls: [Call] = []

    func complete(_ request: DashiiRequest) async throws -> String {
        calls.append(Call(system: request.system, prompt: request.prompt, outputSchema: request.outputSchema, effort: request.effort, model: request.model))
        if let error { throw error }
        return reply
    }
}

/// Stands in for the `github` integration plugin: a stubbed connection plus the exports it publishes.
@MainActor
final class FakeGitHub: Integration {
    let id = "github"
    let name = "GitHub"
    let systemImage = "chevron.left.forwardslash.chevron.right"
    var isConnected = true
    var exports: JSONValue
    let host: String

    init(host: String, login: String = "me", repos: [String] = ["acme/api"]) {
        self.host = host
        exports = ["login": .string(login), "repos": .array(repos.map(JSONValue.string)), "apiURL": .string("https://\(host)")]
    }

    var connection: IntegrationConnection? {
        guard isConnected else { return nil }
        return IntegrationConnection(
            baseURL: URL(string: "https://\(host)")!,
            headers: ["Authorization": "Bearer t0ken", "Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"],
            session: StubProtocol.session())
    }
}

@MainActor
final class FakeHost: ExtensionContext, @unchecked Sendable {
    let context: ModelContext
    var extensions: [any DashExtension]
    let permissions: any PermissionAsking = FakePermissions()
    let fakeDashii = FakeDashii()
    var dashii: any DashiiService { fakeDashii }
    let activity = ActivityLog()
    /// Its own mirror: the default one is shared by every test in the process.
    let synced: any SyncedStore = MemorySyncedStore()
    private(set) var asked: [String] = []
    private(set) var opened: [String?] = []

    init(_ extensions: [any DashExtension]) {
        let container = try! ModelContainer(for: PullRequest.self, PRReview.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        self.extensions = extensions
    }

    func isEnabled(_ item: any DashExtension) -> Bool { true }
    func askDashii(_ prompt: String) { asked.append(prompt) }
    func openManager(_ extensionID: String?) { opened.append(extensionID) }
    func addWidget(kind: String) throws {}
}

/// A feature wired to a fake host and GitHub on a unique stub host. Polling is stopped; tests call `sync()`.
@MainActor
struct Harness {
    let feature: PullRequestsFeature
    let github: FakeGitHub
    let host: FakeHost
    let apiHost: String

    init(repos: [String] = ["acme/api"], login: String = "me", autoReview: Bool = true) {
        apiHost = "gh-\(UUID().uuidString.lowercased()).test"
        let suite = "PullRequestsPluginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        feature = PullRequestsFeature(defaults: defaults)
        feature.autoReview = autoReview
        github = FakeGitHub(host: apiHost, login: login, repos: repos)
        host = FakeHost([github, feature])
        feature.start(host: host)
        feature.stop()
    }

    var dashii: FakeDashii { host.fakeDashii }
    var requests: [URLRequest] { StubProtocol.requests(apiHost) }

    func serve(_ routes: [String: StubProtocol.Reply]) { StubProtocol.serve(apiHost, routes: routes) }

    func tool(_ name: String) throws -> DashiiTool {
        guard let tool = feature.tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
        return tool
    }

    func pulls() -> [PullRequest] { (try? host.context.fetch(FetchDescriptor<PullRequest>(sortBy: [SortDescriptor(\.number)]))) ?? [] }
    func reviews() -> [PRReview] { (try? host.context.fetch(FetchDescriptor<PRReview>())) ?? [] }
}

/// GitHub pulls-list JSON.
enum Fixtures {
    static func pull(_ number: Int, sha: String, author: String = "octocat", draft: Bool = false, requested: [String] = [],
                     title: String? = nil, updated: String = "2026-11-10T09:30:00Z") -> String {
        let reviewers = requested.map { #"{"login":"\#($0)"}"# }.joined(separator: ",")
        return """
            {"number":\(number),"title":"\(title ?? "PR \(number)")","user":{"login":"\(author)"},"body":"Fixes the thing.",
             "html_url":"https://github.com/acme/api/pull/\(number)","draft":\(draft),
             "head":{"sha":"\(sha)","ref":"feature-\(number)"},"base":{"ref":"main"},
             "created_at":"2026-11-09T08:00:00Z","updated_at":"\(updated)","requested_reviewers":[\(reviewers)]}
            """
    }

    static func list(_ items: String...) -> String { "[" + items.joined(separator: ",") + "]" }

    static let review = """
        {"verdict":"request_changes","risk":"high","summary":"Adds retries; 4xx responses are retried too.",
         "testing":"No test for the give-up path.",
         "findings":[
           {"file":"Sources/Fetcher.swift","line":58,"severity":"major","title":"Retries 4xx",
            "detail":"shouldRetry is true for | every error\\nincluding 404.","suggestion":"Retry 429 and 5xx only."},
           {"file":"README.md","line":0,"severity":"nit","title":"Typo","detail":"recieve","suggestion":""}
         ]}
        """
}
