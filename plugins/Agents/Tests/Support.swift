import DashKit
import ClaudeCodeKit
import Foundation
import SwiftData
import SwiftUI

/// Serves canned responses per host, so parallel tests (each with its own host) don't collide.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]

    static func serve(_ host: String, _ handler: @escaping Handler) {
        lock.withLock {
            handlers[host] = handler
            log[host] = []
        }
    }

    static func serve(_ host: String, json: String, status: Int = 200) {
        serve(host) { _ in (status, Data(json.utf8)) }
    }

    static func requests(_ host: String) -> [URLRequest] { lock.withLock { log[host] ?? [] } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.log[host, default: []].append(request)
            return Self.handlers[host]
        }
        let (status, body) = handler?(request) ?? (599, Data("no stub for \(host)".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class FakePermissions: PermissionAsking {
    func ask(icon: String, title: String, message: String, details: [PermissionDetail], allowLabel: String, denyLabel: String) async -> Bool { false }
}

@MainActor
final class FakeClaude: ClaudeService {
    var model: String { "test" }
    func complete(system: String, prompt: String, outputSchema: JSONValue?, effort: String?) async throws -> String { "" }
}

/// Stands in for an integration (`atlassian`, `github`) with a stubbed connection.
@MainActor
final class FakeIntegration: Integration {
    let id: String
    let name: String
    let systemImage = "link"
    let baseURL: URL
    var isConnected: Bool { true }

    init(id: String, baseURL: URL) {
        self.id = id
        name = id
        self.baseURL = baseURL
    }

    var connection: IntegrationConnection? {
        IntegrationConnection(baseURL: baseURL, headers: ["Authorization": "Bearer fake"], session: URLSession(configuration: StubProtocol.configuration()))
    }
}

@MainActor
final class FakeHost: ExtensionContext, @unchecked Sendable {
    let context: ModelContext
    var extensions: [any DashExtension]
    let permissions: any PermissionAsking = FakePermissions()
    let claude: any ClaudeService = FakeClaude()
    let activity = ActivityLog()
    /// Extensions hold their host weakly; keep test hosts alive for the whole run.
    static var alive: [FakeHost] = []

    init(_ extensions: [any DashExtension]) {
        let container = try! ModelContainer(for: Schema([AgentSession.self, AgentMessage.self, PullRequestTemplate.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        self.extensions = extensions
    }

    func isEnabled(_ item: any DashExtension) -> Bool { true }
    func askClaude(_ prompt: String) {}
    func openManager(_ extensionID: String?) {}
    func addWidget(kind: String) throws {}
}

/// An agents extension on its own preferences domain, started on a fake host.
@MainActor
func makeAgents(_ integrations: [any DashExtension] = [], configure: (UserDefaults) -> Void = { _ in }) -> (AgentsExtension, FakeHost) {
    let suite = "AgentsPluginTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    configure(defaults)
    let agents = AgentsExtension(defaults: defaults)
    let host = FakeHost([agents] + integrations)
    FakeHost.alive.append(host)
    agents.start(host: host)
    return (agents, host)
}

/// A CLI stream-json line as ClaudeCodeKit parses it.
func cliMessage(_ line: String) throws -> Message {
    Message(try ClaudeCodeKit.JSON.parse(line))
}
