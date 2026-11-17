@_spi(DashHost) import DashKit
import Foundation
import Testing

/// Answers every request from a handler and records what was sent. No real network. A handler
/// served for one host (`serve`) wins over the shared one, so suites running side by side on
/// their own hosts don't see each other's replies.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var body = Data()
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: @Sendable (URLRequest) -> Response = { _ in Response() }
    nonisolated(unsafe) private static var recorded: [(request: URLRequest, body: Data?)] = []
    nonisolated(unsafe) private static var hosts: [String: @Sendable (URLRequest) -> Response] = [:]
    nonisolated(unsafe) private static var recordedByHost: [String: [(request: URLRequest, body: Data?)]] = [:]

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [(request: URLRequest, body: Data?)] { lock.withLock { recorded } }

    static func serve(_ host: String, _ handler: @escaping @Sendable (URLRequest) -> Response) {
        lock.withLock {
            hosts[host] = handler
            recordedByHost[host] = []
        }
    }

    static func requests(_ host: String) -> [(request: URLRequest, body: Data?)] { lock.withLock { recordedByHost[host] ?? [] } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let host = request.url?.host() ?? ""
        let response = Self.lock.withLock {
            if let handler = Self.hosts[host] {
                Self.recordedByHost[host, default: []].append((request, body))
                return handler
            }
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
        secrets = SecretStore(extensionID: "atlassian-test-\(unique)", legacy: ["token": [legacyAccount, jiraAccount]])
    }

    func integration() -> AtlassianIntegration {
        AtlassianIntegration(defaults: defaults, secrets: secrets, session: StubURLProtocol.session())
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
        #expect(atlassian.metadata.version == "1.7.0" && atlassian.metadata.minimumDashKit == "2.4.0")
        #expect(atlassian.metadata.category == .projectManagement)
        #expect(atlassian.metadata.author == .dash)
        #expect(atlassian.metadata.homepage == "https://github.com/sessaidi/dash")
        #expect(atlassian.tools.map(\.name) == [
            "confluence_search", "confluence_get_page", "confluence_page_children", "confluence_page_attachments", "confluence_spaces",
            "jira_myself_issues", "jira_jql_search", "jira_issue", "jira_issue_comments", "jira_issue_changelog", "jira_projects",
            "atlassian_cached",
        ])
        // Every tool only reads what Dash stored; the fetchers go online.
        #expect(atlassian.tools.allSatisfy { $0.isForDashii && !$0.requiresApproval })
        #expect(atlassian.fetchers.map(\.name) == [
            "confluence.search", "confluence.page", "confluence.children", "confluence.attachments", "confluence.spaces",
            "jira.my_issues", "jira.search", "jira.issue", "jira.comments", "jira.changelog", "jira.projects", "confluence.pages",
        ])
        #expect(AtlassianPlugin.makeExtensions().map(\.id) == ["atlassian"])
    }

    @Test func productionStorageContract() {
        let atlassian = AtlassianIntegration()
        #expect(atlassian.secrets?.extensionID == "atlassian")
        #expect(atlassian.secrets?.legacy == ["token": ["atlassian", "jira"]])
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
}
