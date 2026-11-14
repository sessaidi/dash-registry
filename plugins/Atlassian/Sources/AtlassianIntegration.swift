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
        version: "1.1.0", author: .dash, summary: "Jira and Confluence Cloud with one site, email and API token.",
        category: .projectManagement, tags: ["jira", "confluence"], homepage: "https://github.com/sessaidi/dash")
    let secretKeys = [SecretKey("token", "API token")]
    @ObservationIgnored let secrets: SecretStore?

    var site: String { didSet { defaults.set(site, forKey: "atlassian.site") } }
    var email: String { didSet { defaults.set(email, forKey: "atlassian.email") } }
    private(set) var hasToken: Bool
    private(set) var accountName: String?
    private(set) var lastError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let legacyTokenAccount: String
    @ObservationIgnored private let session: URLSession?

    /// Defaults are the production storage; tests inject their own suite, keychain accounts and session.
    init(
        defaults: UserDefaults = .standard,
        secrets: SecretStore = SecretStore(extensionID: "atlassian", legacy: ["token": "atlassian"]),
        legacyTokenAccount: String = "jira",
        session: URLSession? = nil
    ) {
        self.defaults = defaults
        self.secrets = secrets
        self.legacyTokenAccount = legacyTokenAccount
        self.session = session
        // Earlier builds stored these under "jira".
        site = defaults.string(forKey: "atlassian.site") ?? defaults.string(forKey: "jira.site") ?? ""
        email = defaults.string(forKey: "atlassian.email") ?? defaults.string(forKey: "jira.email") ?? ""
        hasToken = (secrets.read("token") ?? Keychain.read(legacyTokenAccount)) != nil
    }

    /// The stored API token: this extension's item, its legacy "atlassian" item, then the old "jira" item.
    var token: String? { secrets?.read("token") ?? Keychain.read(legacyTokenAccount) }

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
        if token.isEmpty { Keychain.write(nil, for: legacyTokenAccount) }
        hasToken = !token.isEmpty
        Task { await verify() }
    }

    func start(host: any ExtensionContext) {
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

    private func requireConnection() throws -> IntegrationConnection {
        guard siteURL != nil else { throw ToolError("Set your Atlassian site (https://your-team.atlassian.net) in Settings › Atlassian.") }
        guard let connection else { throw ToolError("Add your Atlassian email and API token in Settings › Atlassian.") }
        return connection
    }

    /// GET `path` with a query string and parse JSON.
    private func get(_ path: String, query: [URLQueryItem], service: String) async throws -> JSONValue {
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
    private func post(_ path: String, body: JSONValue, service: String) async throws -> JSONValue {
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

    private struct SearchInput: Decodable { let query: String; let space: String? }
    private struct PageInput: Decodable { let id: String }

    var tools: [ClaudeTool] {
        [
            ClaudeTool(
                name: "confluence_search",
                description: "Search Confluence pages by text (CQL siteSearch). Call when the user asks about docs, runbooks, designs or decisions that might be written down.",
                properties: ["query": JSONSchema.string("Words to search for."), "space": JSONSchema.string("Optional space key to search in.")],
                required: ["query"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(SearchInput.self)
                var cql = "siteSearch ~ \"\(request.query.replacingOccurrences(of: "\"", with: "\\\""))\" AND type = page"
                if let space = request.space, !space.isEmpty { cql += " AND space = \"\(space.replacingOccurrences(of: "\"", with: ""))\"" }
                let result = try await get(
                    "/wiki/rest/api/search", query: [URLQueryItem(name: "cql", value: cql), URLQueryItem(name: "limit", value: "15")],
                    service: "Confluence")
                let site = siteURL?.absoluteString ?? ""
                return .array((result["results"]?.array ?? []).map { item in
                    ["id": item["content"]?["id"] ?? .null, "title": item["content"]?["title"] ?? item["title"] ?? .null,
                     "space": item["resultGlobalContainer"]?["title"] ?? .null, "excerpt": item["excerpt"] ?? .null,
                     "url": .string(site + "/wiki" + (item["url"]?.string ?? ""))]
                })
            },
            ClaudeTool(
                name: "confluence_get_page",
                description: "Read a Confluence page's text by id (from confluence_search). Long pages are cut at 60,000 characters.",
                properties: ["id": JSONSchema.string("Page id.")], required: ["id"]
            ) { [weak self] input in
                guard let self else { return nil }
                let id = try input.toolInput(PageInput.self).id
                guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw ToolError("Page id should be letters and digits, like 123456.") }
                let page = try await get("/wiki/rest/api/content/\(id)", query: [URLQueryItem(name: "expand", value: "body.storage,version,space")], service: "Confluence")
                let text = Self.text(fromStorage: page["body"]?["storage"]?["value"]?.string ?? "")
                return ["title": page["title"] ?? .null, "space": page["space"]?["name"] ?? .null,
                        "version": page["version"]?["number"] ?? .null,
                        "text": .string(text.count > 60_000 ? String(text.prefix(60_000)) + "\n[truncated]" : text)]
            },
            ClaudeTool(
                name: "jira_myself_issues",
                description: "List the open Jira issues assigned to the signed-in user (not Done), most recently updated first, up to 50. Returns key, summary, status and url.",
                properties: [:]
            ) { [weak self] _ in
                guard let self else { return nil }
                let result = try await post("/rest/api/3/search/jql", body: Self.myIssuesBody, service: "Jira")
                let site = siteURL?.absoluteString ?? ""
                return .array((result["issues"]?.array ?? []).map { issue in
                    let key = issue["key"]?.string ?? ""
                    return ["key": .string(key), "summary": issue["fields"]?["summary"] ?? .null,
                            "status": issue["fields"]?["status"]?["name"] ?? .null,
                            "url": .string(site + "/browse/" + key)]
                })
            },
        ]
    }
}

private struct AtlassianSettings: View {
    @Bindable var atlassian: AtlassianIntegration

    var body: some View {
        Form {
            Section {
                TextField("Site", text: $atlassian.site, prompt: Text("https://your-team.atlassian.net"))
                TextField("Email", text: $atlassian.email)
                SecretField("API token", placeholder: "Create at id.atlassian.com", isStored: atlassian.hasToken,
                            onSave: { atlassian.setToken($0) }, onRemove: { atlassian.setToken("") })
                // Atlassian's page doesn't take pre-filled values: name it "Dash" there.
                Link("Create an API token at id.atlassian.com (name it “Dash”)",
                     destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!).font(.callout)
                HStack {
                    ConnectionStatusLabel(atlassian.connectionState)
                    Spacer()
                    AsyncButton("Check") { await atlassian.verify() }
                }
            } header: {
                Text("Account")
            } footer: {
                Link("Create an API token (used for Jira and Confluence)", destination: URL(string: "https://id.atlassian.com/manage-profile/security/api-tokens")!)
            }
        }
        .formStyle(.grouped)
    }
}
