import DashKit
import Foundation
import Testing

/// Answers every request from a handler and records what was sent. No real network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var body = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: @Sendable (URLRequest) -> Response = { _ in Response() }
    nonisolated(unsafe) private static var recorded: [(request: URLRequest, body: Data?)] = []

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [(request: URLRequest, body: Data?)] { lock.withLock { recorded } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let response = Self.lock.withLock {
            Self.recorded.append((request, body))
            return Self.handler
        }(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Isolated storage per test: its own defaults suite and keychain accounts, removed afterwards.
@MainActor
final class Sandbox {
    let suiteName = "dev.sessaidi.Dash.plugin.atlassian.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let secrets: SecretStore
    let legacyAccount: String
    let jiraAccount: String

    init() {
        let unique = UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        legacyAccount = "atlassian-test-legacy-\(unique)"
        jiraAccount = "jira-test-\(unique)"
        secrets = SecretStore(extensionID: "atlassian-test-\(unique)", legacy: ["token": legacyAccount])
    }

    func integration() -> AtlassianIntegration {
        AtlassianIntegration(defaults: defaults, secrets: secrets, legacyTokenAccount: jiraAccount, session: StubURLProtocol.session())
    }

    func configure(site: String = "https://acme.atlassian.net", email: String = "me@acme.dev", token: String = "s3cret") {
        defaults.set(site, forKey: "atlassian.site")
        defaults.set(email, forKey: "atlassian.email")
        secrets.write("token", token)
    }

    func cleanUp() {
        Keychain.write(nil, for: secrets.account("token"))
        Keychain.write(nil, for: legacyAccount)
        Keychain.write(nil, for: jiraAccount)
        defaults.removePersistentDomain(forName: suiteName)
    }
}

@MainActor
@Suite(.serialized)
struct AtlassianIntegrationTests {
    @Test func identityAndMetadata() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let atlassian = sandbox.integration()
        #expect(atlassian.id == "atlassian")
        #expect(atlassian.layer == .integration)
        #expect(atlassian.metadata.version == "1.3.0")
        #expect(atlassian.metadata.category == .projectManagement)
        #expect(atlassian.metadata.author == .dash)
        #expect(atlassian.metadata.homepage == "https://github.com/sessaidi/dash")
        #expect(atlassian.tools.map(\.name) == [
            "confluence_search", "confluence_get_page", "confluence_page_children", "confluence_page_attachments", "confluence_spaces",
            "jira_myself_issues", "jira_jql_search", "jira_issue", "jira_issue_comments", "jira_issue_changelog", "jira_projects",
            "atlassian_cached",
        ])
        // Every tool only reads.
        #expect(atlassian.tools.allSatisfy { !$0.requiresApproval && !$0.writesRemotely })
        #expect(AtlassianPlugin.makeExtensions().map(\.id) == ["atlassian"])
    }

    @Test func productionStorageContract() {
        let atlassian = AtlassianIntegration()
        #expect(atlassian.secrets?.extensionID == "atlassian")
        #expect(atlassian.secrets?.legacy == ["token": "atlassian"])
        #expect(atlassian.secrets?.account("token") == "atlassian.token")
    }

    @Test func notConnectedWithoutCredentials() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let atlassian = sandbox.integration()
        #expect(atlassian.connection == nil)
        #expect(!atlassian.isConnected)
        #expect(atlassian.connectionState == .notConfigured)
    }

    @Test func basicAuthHeaderAndVerify() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        sandbox.configure()
        StubURLProtocol.reset { _ in .init(body: Data(#"{"displayName":"Ada Lovelace","accountId":"abc"}"#.utf8)) }
        let atlassian = sandbox.integration()

        let connection = try #require(atlassian.connection)
        #expect(connection.baseURL.absoluteString == "https://acme.atlassian.net")
        let expected = "Basic " + Data("me@acme.dev:s3cret".utf8).base64EncodedString()
        #expect(connection.headers["Authorization"] == expected)
        #expect(connection.headers["Accept"] == "application/json")

        await atlassian.verify()
        let request = try #require(StubURLProtocol.requests.first?.request)
        #expect(request.url?.absoluteString == "https://acme.atlassian.net/rest/api/3/myself")
        #expect(request.value(forHTTPHeaderField: "Authorization") == expected)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(atlassian.accountName == "Ada Lovelace")
        #expect(atlassian.connectionState == .connected("Signed in as Ada Lovelace"))
    }

    @Test func verifyFailureIsReported() async {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        sandbox.configure()
        StubURLProtocol.reset { _ in .init(status: 401, body: Data("{}".utf8)) }
        let atlassian = sandbox.integration()
        await atlassian.verify()
        guard case .failed(let message) = atlassian.connectionState else {
            Issue.record("expected failure, got \(atlassian.connectionState)")
            return
        }
        #expect(message.contains("401"))
    }

    @Test func exports() async {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        sandbox.configure(site: " https://acme.atlassian.net/ ")
        StubURLProtocol.reset { _ in .init(body: Data(#"{"displayName":"Ada"}"#.utf8)) }
        let atlassian = sandbox.integration()
        #expect(atlassian.exports == ["site": "https://acme.atlassian.net", "email": "me@acme.dev", "accountName": nil])
        await atlassian.verify()
        #expect(atlassian.exports == ["site": "https://acme.atlassian.net", "email": "me@acme.dev", "accountName": "Ada"])
    }

    @Test func editingWritesAtlassianKeys() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let atlassian = sandbox.integration()
        atlassian.site = "https://other.atlassian.net"
        atlassian.email = "x@y.z"
        #expect(sandbox.defaults.string(forKey: "atlassian.site") == "https://other.atlassian.net")
        #expect(sandbox.defaults.string(forKey: "atlassian.email") == "x@y.z")
    }

    @Test func legacyPreferencesFallBackToJiraKeys() {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        sandbox.defaults.set("https://old.atlassian.net", forKey: "jira.site")
        sandbox.defaults.set("old@acme.dev", forKey: "jira.email")
        var atlassian = sandbox.integration()
        #expect(atlassian.site == "https://old.atlassian.net")
        #expect(atlassian.email == "old@acme.dev")

        sandbox.defaults.set("https://new.atlassian.net", forKey: "atlassian.site")
        sandbox.defaults.set("new@acme.dev", forKey: "atlassian.email")
        atlassian = sandbox.integration()
        #expect(atlassian.site == "https://new.atlassian.net")
        #expect(atlassian.email == "new@acme.dev")
    }

    @Test func tokenFallsBackToLegacyAccounts() throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        sandbox.defaults.set("https://acme.atlassian.net", forKey: "jira.site")
        sandbox.defaults.set("me@acme.dev", forKey: "jira.email")

        // Oldest builds: the "jira" account.
        #expect(Keychain.write("from-jira", for: sandbox.jiraAccount))
        var atlassian = sandbox.integration()
        #expect(atlassian.hasToken)
        #expect(atlassian.token == "from-jira")
        #expect(try #require(atlassian.connection).headers["Authorization"] == "Basic " + Data("me@acme.dev:from-jira".utf8).base64EncodedString())

        // Then the SecretStore legacy account ("atlassian" in production).
        #expect(Keychain.write("from-legacy", for: sandbox.legacyAccount))
        atlassian = sandbox.integration()
        #expect(atlassian.token == "from-legacy")

        // The extension's own item wins.
        sandbox.secrets.write("token", "current")
        atlassian = sandbox.integration()
        #expect(atlassian.token == "current")
    }

    @Test func storageToText() {
        let html = "<h1>Runbook</h1><p>Restart &amp; check <strong>logs</strong>.</p><ul><li>One</li><li>Two &lt;3&gt;</li></ul><p>Line<br/>break&nbsp;here &quot;ok&quot; it&#39;s</p><p></p><p></p><p>End &amp;lt;</p>"
        #expect(AtlassianIntegration.text(fromStorage: html) == "Runbook\nRestart & check logs.\nOne\nTwo <3>\nLine\nbreak here \"ok\" it's\n\nEnd &lt;")
    }

    @Test func confluenceGetPage() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        sandbox.configure()
        StubURLProtocol.reset { _ in
            .init(body: Data(#"{"id":"12345","title":"Runbook","space":{"key":"OPS","name":"Ops"},"version":{"number":7,"when":"2026-11-01T10:00:00Z","by":{"displayName":"Ada"}},"_links":{"webui":"/spaces/OPS/pages/12345"},"metadata":{"labels":{"results":[{"name":"oncall"}]}},"ancestors":[{"id":"1","title":"Ops home"}],"body":{"storage":{"value":"<p>Hello &amp; bye</p>"}}}"#.utf8))
        }
        let atlassian = sandbox.integration()
        let tool = try #require(atlassian.tools.first { $0.name == "confluence_get_page" })
        let result = try await tool.run(["id": "12345"])
        #expect(result["title"] == "Runbook" && result["space"]?["name"] == "Ops" && result["version"] == 7)
        #expect(result["markdown"] == "Hello & bye" && result["labels"] == ["oncall"] && result["ancestors"]?[0]?["title"] == "Ops home")
        #expect(result["url"] == "https://acme.atlassian.net/wiki/spaces/OPS/pages/12345" && result["from_cache"] == false)
        let url = try #require(StubURLProtocol.requests.first?.request.url)
        #expect(url.path() == "/wiki/rest/api/content/12345")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "expand", value: "body.storage,version,space,ancestors,metadata.labels")])
        await #expect(throws: ToolError.self) { try await tool.run(["id": "../../x"]) }
    }

    @Test func confluenceSearch() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        sandbox.configure()
        StubURLProtocol.reset { _ in
            .init(body: Data(#"{"results":[{"content":{"id":"9","title":"Deploys"},"resultGlobalContainer":{"title":"Eng"},"excerpt":"how to","url":"/spaces/ENG/pages/9"}]}"#.utf8))
        }
        let atlassian = sandbox.integration()
        let tool = try #require(atlassian.tools.first { $0.name == "confluence_search" })
        let result = try await tool.run(["query": "c++ \"deploy\"", "space": "ENG"])
        #expect(result == [["id": "9", "title": "Deploys", "space": "Eng", "excerpt": "how to", "url": "https://acme.atlassian.net/wiki/spaces/ENG/pages/9"]])
        let url = try #require(StubURLProtocol.requests.first?.request.url)
        #expect(url.path() == "/wiki/rest/api/search")
        #expect(url.query()?.contains("c%2B%2B") == true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "cql" }?.value == #"siteSearch ~ "c++ \"deploy\"" AND type = page AND space = "ENG""#)
        #expect(items.first { $0.name == "limit" }?.value == "15")
    }

    @Test func myselfIssuesRequestAndResult() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        sandbox.configure()
        StubURLProtocol.reset { _ in
            .init(body: Data(#"{"issues":[{"key":"DASH-1","fields":{"summary":"Ship plugins","status":{"name":"In Progress"},"priority":{"name":"High"},"updated":"2026-11-01T10:00:00.000+0000"}}]}"#.utf8))
        }
        let atlassian = sandbox.integration()
        let tool = try #require(atlassian.tools.first { $0.name == "jira_myself_issues" })
        let result = try await tool.run([:])
        #expect(result == [["key": "DASH-1", "summary": "Ship plugins", "status": "In Progress", "url": "https://acme.atlassian.net/browse/DASH-1"]])

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://acme.atlassian.net/rest/api/3/search/jql")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Basic " + Data("me@acme.dev:s3cret".utf8).base64EncodedString())
        let body = try JSONValue.parse(try #require(sent.body))
        #expect(body == [
            "jql": "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC",
            "fields": ["summary", "status", "priority", "updated"],
            "maxResults": 50,
        ])
    }

    @Test func toolsExplainMissingSetup() async throws {
        let sandbox = Sandbox()
        defer { sandbox.cleanUp() }
        let atlassian = sandbox.integration()
        let tool = try #require(atlassian.tools.first { $0.name == "jira_myself_issues" })
        await #expect(throws: ToolError("Set your Atlassian site (https://your-team.atlassian.net) in Settings › Atlassian.")) { try await tool.run([:]) }
    }
}
