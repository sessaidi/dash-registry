import DashKit
import Foundation
import SwiftData
import SwiftUI

/// Serves canned responses per host, so parallel tests (each with its own host) don't collide.
/// Request bodies are read into `httpBody` before handlers and the log see them.
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

    /// Replies by "METHOD /path"; anything else is a 404.
    static func serve(_ host: String, routes: [String: String]) {
        serve(host) { request in
            let route = "\(request.httpMethod ?? "GET") \(request.url?.path() ?? "")"
            guard let body = routes[route] else { return (404, Data(#"{"errorMessages":["no route \#(route)"]}"#.utf8)) }
            return (200, Data(body.utf8))
        }
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
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream { request.httpBody = Self.read(stream) }
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

    private static func read(_ stream: InputStream) -> Data {
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

extension URLRequest {
    /// The JSON body a test request carried.
    var jsonBody: JSONValue? { httpBody.flatMap { try? JSONValue.parse($0) } }

    func query(_ name: String) -> String? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == name }?.value
    }
}

@MainActor
final class FakePermissions: PermissionAsking {
    func ask(_ prompt: PermissionPrompt) async -> Bool { false }
}

@MainActor
final class FakeDashii: DashiiService {
    var model: String { "test" }
    func complete(_ request: DashiiRequest) async throws -> String { "" }
}

/// Stands in for the `atlassian` plugin: a Basic-auth connection to `https://<host>`.
@MainActor
final class FakeAtlassian: Integration {
    let id = "atlassian"
    let name = "Atlassian"
    let systemImage = "building.columns"
    var connected = true
    private let host: String
    private let session = URLSession(configuration: StubProtocol.configuration())

    init(host: String) {
        self.host = host
    }

    var isConnected: Bool { connected }
    var connection: IntegrationConnection? {
        guard connected else { return nil }
        return IntegrationConnection(
            baseURL: URL(string: "https://\(host)")!,
            headers: ["Authorization": "Basic dGVzdEBleGFtcGxlLmNvbTp0b2tlbg==", "Accept": "application/json"], session: session)
    }
    var exports: JSONValue { ["site": .string("https://\(host)"), "email": "test@example.com", "accountName": "Test User"] }

    /// Atlassian 1.7 and later: readers answering from `stored` (by reader name), and their fetchers.
    var fetchesThenReads = true
    var stored: [String: JSONValue] = [:]
    private(set) var reads: [(reader: String, input: JSONValue)] = []

    var tools: [DashiiTool] {
        guard fetchesThenReads else { return [] }
        return ["jira_issue", "jira_jql_search"].map { name in
            DashiiTool(name: name, description: name) { [weak self] input in
                self?.reads.append((name, input))
                return self?.stored[name] ?? ["fetched": false, "rows": []]
            }
        }
    }

    var fetchers: [DataFetcher] {
        fetchesThenReads ? ["jira.issue", "jira.search"].map { DataFetcher(name: $0, summary: $0) { _ in [:] } } : []
    }
}

@MainActor
final class FakeHost: ExtensionContext, @unchecked Sendable {
    let context: ModelContext
    var extensions: [any DashExtension]
    let permissions: any PermissionAsking = FakePermissions()
    let dashii: any DashiiService = FakeDashii()
    let activity = ActivityLog()

    init(_ extensions: [any DashExtension]) {
        let container = try! ModelContainer(for: Schema([JiraIssue.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        context = ModelContext(container)
        self.extensions = extensions
    }

    func isEnabled(_ item: any DashExtension) -> Bool { true }
    func askDashii(_ prompt: String) {}
    func openManager(_ extensionID: String?) {}
    func addWidget(kind: String) throws {}
}

/// A feature wired to a fake Atlassian on `host`, with its own preferences suite.
/// The poller is cancelled before it runs, so tests drive `sync()` themselves. The feature holds
/// the host weakly (as in Dash), so tests keep the returned host alive.
@MainActor
func makeFeature(host name: String, boardID: String = "", followJQL: String = "") -> (JiraBoardFeature, FakeHost, FakeAtlassian) {
    let defaults = UserDefaults(suiteName: "jira-board-tests-\(UUID().uuidString)")!
    defaults.set(boardID, forKey: "jira-board.boardID")
    defaults.set(followJQL, forKey: "jira-board.jql")
    let feature = JiraBoardFeature(defaults: defaults)
    let atlassian = FakeAtlassian(host: name)
    let host = FakeHost([atlassian, feature])
    feature.start(host: host)
    feature.stop()
    return (feature, host, atlassian)
}

/// A Jira issue as the REST API returns it (search, agile and issue endpoints share this shape).
func issueJSON(_ key: String, summary: String = "Summary", statusID: String = "3", status: String = "In Progress",
               category: String = "indeterminate", assignee: String? = "Maya Chen", updated: String = "2026-03-04T10:20:30.000+0000") -> String {
    let assigneeJSON = assignee.map { #"{"displayName":"\#($0)"}"# } ?? "null"
    return """
        {"key":"\(key)","fields":{"summary":"\(summary)","status":{"id":"\(statusID)","name":"\(status)","statusCategory":{"key":"\(category)"}},
         "assignee":\(assigneeJSON),"priority":{"name":"High"},"issuetype":{"name":"Story"},"updated":"\(updated)","labels":["web","q2"]}}
        """
}

func issuesPage(_ issues: [String], next: String? = nil) -> String {
    #"{"issues":[\#(issues.joined(separator: ","))]"# + (next.map { #","nextPageToken":"\#($0)""# } ?? "") + "}"
}
