import DashKit
import DashKitUI
import Foundation
import Ingestor
import Observation
import SwiftUI

/// Layer 1 for GitHub: the account (token, API URL) and the repositories you watch.
/// Features such as Pull Requests build on it through `connection` and `exports`.
@MainActor
@Observable
final class GitHubIntegration: Integration {
    static let defaultAPI = "https://api.github.com"
    static let apiKey = "github.api"
    static let reposKey = "github.repos"
    static let freshKey = "github.freshMinutes"

    let id = "github"
    let name = "GitHub"
    let systemImage = "chevron.left.forwardslash.chevron.right"
    let metadata = ExtensionMetadata(
        version: "1.10.0", author: .dash, summary: "GitHub account, API URL and the repositories you watch.",
        category: .sourceControl, tags: ["github", "git", "pull requests"], homepage: "https://github.com/sessaidi/dash",
        minimumDashKit: "2.4.0")
    let secretKeys = [SecretKey("token", "Personal access token")]
    let secrets: SecretStore? = SecretStore(extensionID: "github", legacy: ["token": "github"])

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readToken: @MainActor () -> String?
    /// URLSession for requests; nil uses the shared session. Tests inject a stubbed one.
    @ObservationIgnored private let session: URLSession?
    /// Dash, once started: fetchers and the sync tools write into its synced store.
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    /// Where `github.store` (the pull request and run tables) lives; nil keeps it in memory (tests).
    @ObservationIgnored let databaseFolder: URL?
    /// The tables, once started.
    @ObservationIgnored var database: IngestDatabase?

    /// https://api.github.com, or https://<host>/api/v3 for GitHub Enterprise Server.
    var apiURL: String { didSet { defaults.set(apiURL, forKey: Self.apiKey) } }
    /// Watched repositories, "owner/name", one per line. Shared by every GitHub feature.
    var reposText: String { didSet { defaults.set(reposText, forKey: Self.reposKey); publishRepos() } }
    /// Fetched data older than this is stale: readers say so and Dashii may fetch it again.
    var freshMinutes: Int { didSet { defaults.set(freshMinutes, forKey: Self.freshKey) } }
    /// The clock for freshness (tests move it).
    @ObservationIgnored var now: @MainActor () -> Date = { .now }
    private(set) var hasToken: Bool
    private(set) var viewer = ""
    private(set) var lastError: String?
    private(set) var isChecking = false

    /// `token` and `session` exist for tests; the app uses the Keychain and the shared session.
    init(defaults: UserDefaults = DashStorage.defaults, token: (@MainActor () -> String?)? = nil, session: URLSession? = nil, databaseFolder: URL? = nil) {
        let store = SecretStore(extensionID: "github", legacy: ["token": "github"])
        let readToken = token ?? { store.read("token") }
        self.defaults = defaults
        self.readToken = readToken
        self.session = session
        self.databaseFolder = databaseFolder
        apiURL = defaults.string(forKey: Self.apiKey) ?? Self.defaultAPI
        reposText = defaults.string(forKey: Self.reposKey) ?? ""
        freshMinutes = defaults.object(forKey: Self.freshKey) as? Int ?? 15
        hasToken = !(readToken() ?? "").isEmpty
    }

    private var token: String? { readToken().flatMap { $0.isEmpty ? nil : $0 } }

    var isConnected: Bool { hasToken }

    var connectionState: ConnectionState {
        if isChecking && lastError == nil && viewer.isEmpty { return .checking }
        return state(error: lastError, configured: hasToken, account: viewer.isEmpty ? nil : viewer)
    }

    var repos: [String] { GitHubAPI.parseRepos(reposText) }

    /// The website for the API URL (github.com, or the Enterprise host).
    var webURL: String {
        let api = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if api.isEmpty || api.contains("api.github.com") { return "https://github.com" }
        return api.replacingOccurrences(of: "/api/v3", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// GitHub's "new token" page with Dash's name and the permissions its features use filled in.
    /// Fine-grained: Contents, Pull requests (write, for reviews and PRs), Actions, Issues, Metadata.
    var fineGrainedTokenURL: URL? {
        URL(string: webURL + "/settings/personal-access-tokens/new?name=Dash&description=Dash%20dashboard%20(PRs%2C%20reviews%2C%20CI)&expires_in=90"
            + "&contents=read&pull_requests=write&actions=read&issues=read&metadata=read")
    }

    /// The classic-token page with its scopes ticked (repo for private repositories, read:org for org lists).
    var classicTokenURL: URL? {
        URL(string: webURL + "/settings/tokens/new?description=Dash&scopes=repo,read:org")
    }

    /// Repositories the token can see (newest pushes first), for the picker.
    private(set) var availableRepos: [AvailableRepo] = []
    private(set) var loadingRepos = false
    private(set) var reposError: String?
    /// The classic token's scopes, from GitHub's X-OAuth-Scopes header (nil for fine-grained tokens).
    private(set) var tokenScopes: [String]?
    /// Repositories GitHub's search found for the typed text, beyond the loaded list.
    private(set) var searchResults: [AvailableRepo] = []

    struct AvailableRepo: Identifiable, Hashable, Sendable {
        let fullName: String
        let isPrivate: Bool
        let description: String
        let pushedAt: String
        var id: String { fullName }
    }

    /// What's likely wrong when the list comes back short: missing scopes or organization SSO.
    var reposHint: String? {
        if let scopes = tokenScopes {
            let missing = ["repo", "read:org"].filter { !scopes.contains($0) && !(($0 == "read:org") && scopes.contains("admin:org")) }
            if !missing.isEmpty {
                return "This classic token is missing \(missing.joined(separator: " and ")) (it has: \(scopes.isEmpty ? "none" : scopes.joined(separator: ", "))). "
                    + "Without repo only public repositories show; without read:org your organizations' repositories don't."
            }
        }
        if !loadingRepos, reposError == nil, availableRepos.allSatisfy({ !$0.isPrivate }) {
            return "No private repositories visible. If your organization uses SAML single sign-on, open the token on GitHub and choose Configure SSO → Authorize for it."
        }
        return nil
    }

    func loadAvailableRepos() async {
        guard let connection else {
            reposError = hasToken ? "The GitHub API URL is not valid." : "Add a token first."
            return
        }
        guard !loadingRepos else { return }
        loadingRepos = true
        defer { loadingRepos = false }
        var found: [AvailableRepo] = []
        do {
            for page in 1...30 {
                guard let url = connection.url("/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member&page=\(page)") else { break }
                let (data, response) = try await connection.send(URLRequest(url: url), service: "GitHub")
                if page == 1 {
                    tokenScopes = (response.value(forHTTPHeaderField: "X-OAuth-Scopes")).map {
                        $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                }
                let items = try JSONValue.parse(data).array ?? []
                found += items.compactMap { item in
                    guard let name = item["full_name"]?.string else { return nil }
                    return AvailableRepo(fullName: name, isPrivate: item["private"]?.bool ?? false,
                                         description: item["description"]?.string ?? "", pushedAt: item["pushed_at"]?.string ?? "")
                }
                if items.count < 100 { break }
            }
            availableRepos = found
            reposError = nil
        } catch {
            reposError = error.localizedDescription
        }
    }

    /// Searches GitHub for repositories by name (finds ones the list missed, e.g. a big organization's).
    func searchRepos(_ text: String) async {
        let query = text.trimmingCharacters(in: .whitespaces)
        guard query.count >= 3, let connection else { searchResults = []; return }
        // "owner/name" searches inside that owner; otherwise by name anywhere the token can see.
        let parts = query.split(separator: "/", maxSplits: 1).map(String.init)
        let q = parts.count == 2 ? "\(parts[1]) in:name user:\(parts[0])" : "\(query) in:name"
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = connection.url("/search/repositories?per_page=30&q=\(encoded)") else { return }
        do {
            let (data, _) = try await connection.send(URLRequest(url: url), service: "GitHub")
            let known = Set(availableRepos.map(\.fullName))
            searchResults = (try JSONValue.parse(data)["items"]?.array ?? []).compactMap { item in
                guard let name = item["full_name"]?.string, !known.contains(name) else { return nil }
                return AvailableRepo(fullName: name, isPrivate: item["private"]?.bool ?? false,
                                     description: item["description"]?.string ?? "", pushedAt: item["pushed_at"]?.string ?? "")
            }
        } catch {
            searchResults = []
        }
    }

    func setWatched(_ repo: String, _ watched: Bool) {
        var list = repos
        if watched { if !list.contains(repo) { list.append(repo) } } else { list.removeAll { $0 == repo } }
        reposText = list.joined(separator: "\n")
    }

    var connection: IntegrationConnection? {
        let trimmed = apiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token, let api = URL(string: trimmed), api.scheme != nil, api.host() != nil else { return nil }
        return IntegrationConnection(baseURL: api, headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ], session: session)
    }

    var exports: JSONValue {
        var exports: JSONValue = [
            "login": .string(viewer),
            "repos": .array(repos.map { .string($0) }),
            "apiURL": .string(apiURL),
            "webURL": .string(webURL),
        ]
        if let databaseExport { exports = exports.merging(["database": databaseExport]) }
        return exports
    }

    private var api: GitHubAPI {
        get throws {
            guard token != nil else { throw ToolError("Connect GitHub in the Extensions window.") }
            guard let connection else { throw ToolError("The GitHub API URL is not valid.") }
            return GitHubAPI(connection: connection)
        }
    }

    func setToken(_ token: String) {
        secrets?.write("token", token)
        hasToken = !token.isEmpty
        viewer = ""
        lastError = nil
        Task { await verify() }
    }

    func start(host: any ExtensionContext) {
        self.host = host
        openDatabase()
        publishRepos()
        Task { await verify() }
    }

    /// The watched repositories, in Dash's database for other extensions (Knowledge indexes them).
    func publishRepos() {
        guard let host else { return }
        WatchedRepositories.publish(repos, provider: "github", web: webURL, in: host.synced)
    }

    /// Checks the token and learns the signed-in login.
    @discardableResult
    func verify() async -> Bool {
        hasToken = token != nil
        guard hasToken else {
            viewer = ""
            lastError = nil
            return false
        }
        isChecking = true
        defer { isChecking = false }
        do {
            viewer = try await api.viewer()
            lastError = nil
            return true
        } catch {
            viewer = ""
            lastError = error.localizedDescription
            return false
        }
    }

    func ensureViewer() async throws -> String {
        if viewer.isEmpty { viewer = try await api.viewer() }
        return viewer
    }

    func settingsView() -> AnyView { AnyView(GitHubSettingsView(github: self)) }

    /// Cuts `github_api_get` answers (and file reads) at this many characters.
    static let maxToolCharacters = 100_000

    /// The API for the granular tools (throws when GitHub isn't connected).
    var toolAPI: GitHubAPI { get throws { try api } }
}
