import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Layer 1 for Atlassian Cloud: one site, email and API token for Jira and Confluence.
/// Features (Jira Board, Agents, anything declaring `requires: ["atlassian"]`) reach the
/// account through `connection` and read `exports` (`site`, `email`, `accountName`).
@MainActor
@Observable
final class AtlassianIntegration: Integration {
    let id = "atlassian"
    let name = "Atlassian"
    let systemImage = "building.columns"
    let metadata = ExtensionMetadata(
        version: "1.7.0", author: .dash, summary: "Jira and Confluence Cloud with one site, email and API token.",
        category: .projectManagement, tags: ["jira", "confluence"], homepage: "https://github.com/sessaidi/dash", minimumDashKit: "2.4.0")
    let secretKeys = [SecretKey("token", "API token")]
    @ObservationIgnored let secrets: SecretStore?

    var site: String { didSet { defaults.set(site, forKey: "atlassian.site") } }
    var email: String { didSet { defaults.set(email, forKey: "atlassian.email") } }
    private(set) var hasToken: Bool
    private(set) var accountName: String?
    private(set) var lastError: String?
    /// How long fetched Jira and Confluence data stays fresh; older answers are marked stale.
    var cacheMinutes: Int { didSet { defaults.set(cacheMinutes, forKey: "atlassian.cacheMinutes") } }
    /// The host's mirror of online data (Dash's database); nil until started, and in some tests.
    @ObservationIgnored var mirror: (any SyncedStore)?
    /// The clock, for cache ages (tests move it).
    @ObservationIgnored var now: () -> Date = { .now }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession?

    /// Defaults are the production storage; tests inject their own suite, keychain accounts and session.
    init(
        defaults: UserDefaults = DashStorage.defaults,
        // Earlier builds kept the token under "atlassian", and before that "jira".
        secrets: SecretStore = SecretStore(extensionID: "atlassian", legacy: ["token": ["atlassian", "jira"]]),
        session: URLSession? = nil
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.session = session
        // Earlier builds stored these under "jira".
        site = defaults.string(forKey: "atlassian.site") ?? defaults.string(forKey: "jira.site") ?? ""
        email = defaults.string(forKey: "atlassian.email") ?? defaults.string(forKey: "jira.email") ?? ""
        hasToken = secrets.contains("token")
        cacheMinutes = (defaults.object(forKey: "atlassian.cacheMinutes") as? Int) ?? 15
    }

    /// The stored API token: this extension's item, then the legacy "atlassian" and "jira" items.
    var token: String? { secrets?.read("token") }

    var siteURL: URL? {
        let trimmed = site.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), url.scheme == "https", url.host() != nil else { return nil }
        return url
    }

    var isConnected: Bool { connection != nil }
    var connectionState: ConnectionState { state(error: lastError, configured: isConnected, account: accountName) }

    var connection: IntegrationConnection? {
        guard let siteURL, !email.isEmpty, let token, !token.isEmpty else { return nil }
        let auth = Data("\(email):\(token)".utf8).base64EncodedString()
        return IntegrationConnection(
            baseURL: siteURL, headers: ["Authorization": "Basic \(auth)", "Accept": "application/json"], session: session)
    }

    var exports: JSONValue {
        ["site": .string(siteURL?.absoluteString ?? site), "email": .string(email), "accountName": accountName.map { .string($0) } ?? .null]
    }

    func setToken(_ token: String) {
        secrets?.write("token", token)
        hasToken = !token.isEmpty
        Task { await verify() }
    }

    func start(host: any ExtensionContext) {
        mirror = host.synced
        Task { await verify() }
    }

    /// Checks the credentials with /rest/api/3/myself and records the account's display name.
    func verify() async {
        guard let connection else {
            accountName = nil
            lastError = nil
            return
        }
        do {
            accountName = try await connection.get("/rest/api/3/myself", service: "Atlassian")["displayName"]?.string
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func settingsView() -> AnyView { AnyView(AtlassianSettings(atlassian: self)) }

    // MARK: Requests

    func requireConnection() throws -> IntegrationConnection {
        guard siteURL != nil else { throw ToolError("Set your Atlassian site (https://your-team.atlassian.net) in Settings › Atlassian.") }
        guard let connection else { throw ToolError("Add your Atlassian email and API token in Settings › Atlassian.") }
        return connection
    }

    /// GET `path` with a query string and parse JSON.
    func get(_ path: String, query: [URLQueryItem], service: String) async throws -> JSONValue {
        let connection = try requireConnection()
        guard let base = connection.url(path), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ToolError("Bad path \(path)")
        }
        components.queryItems = query
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw ToolError("Bad query for \(path)") }
        let (data, _) = try await connection.send(URLRequest(url: url), service: service)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    /// POST a JSON body to `path` and parse JSON.
    func post(_ path: String, body: JSONValue, service: String) async throws -> JSONValue {
        let connection = try requireConnection()
        guard let url = connection.url(path) else { throw ToolError("Bad path \(path)") }
        let (data, _) = try await connection.send(try HTTP.request(url, method: "POST", body: body), service: service)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    // MARK: Confluence

    /// Confluence storage HTML to readable text.
    nonisolated static func text(fromStorage html: String) -> String {
        var text = html.replacingOccurrences(of: "</p>|<br ?/?>|</h[1-6]>|</li>|</tr>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Jira

    static let myIssuesJQL = "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC"

    /// Body of the `jira_myself_issues` search (POST /rest/api/3/search/jql).
    static var myIssuesBody: JSONValue {
        ["jql": .string(myIssuesJQL), "fields": ["summary", "status", "priority", "updated"], "maxResults": 50]
    }
}
