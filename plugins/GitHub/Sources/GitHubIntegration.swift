import DashKit
import DashKitUI
import Foundation
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

    let id = "github"
    let name = "GitHub"
    let systemImage = "chevron.left.forwardslash.chevron.right"
    let metadata = ExtensionMetadata(
        version: "1.1.0", author: .dash, summary: "GitHub account, API URL and the repositories you watch.",
        category: .sourceControl, tags: ["github", "git", "pull requests"], homepage: "https://github.com/sessaidi/dash",
        minimumDashKit: "1.0.0")
    let secretKeys = [SecretKey("token", "Personal access token")]
    let secrets: SecretStore? = SecretStore(extensionID: "github", legacy: ["token": "github"])

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readToken: @MainActor () -> String?
    /// URLSession for requests; nil uses the shared session. Tests inject a stubbed one.
    @ObservationIgnored private let session: URLSession?

    /// https://api.github.com, or https://<host>/api/v3 for GitHub Enterprise Server.
    var apiURL: String { didSet { defaults.set(apiURL, forKey: Self.apiKey) } }
    /// Watched repositories, "owner/name", one per line. Shared by every GitHub feature.
    var reposText: String { didSet { defaults.set(reposText, forKey: Self.reposKey) } }
    private(set) var hasToken: Bool
    private(set) var viewer = ""
    private(set) var lastError: String?
    private(set) var isChecking = false

    /// `token` and `session` exist for tests; the app uses the Keychain and the shared session.
    init(defaults: UserDefaults = .standard, token: (@MainActor () -> String?)? = nil, session: URLSession? = nil) {
        let store = SecretStore(extensionID: "github", legacy: ["token": "github"])
        let readToken = token ?? { store.read("token") }
        self.defaults = defaults
        self.readToken = readToken
        self.session = session
        apiURL = defaults.string(forKey: Self.apiKey) ?? Self.defaultAPI
        reposText = defaults.string(forKey: Self.reposKey) ?? ""
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

    struct AvailableRepo: Identifiable, Hashable, Sendable {
        let fullName: String
        let isPrivate: Bool
        let description: String
        let pushedAt: String
        var id: String { fullName }
    }

    func loadAvailableRepos() async {
        guard let connection, !loadingRepos else { return }
        loadingRepos = true
        defer { loadingRepos = false }
        var found: [AvailableRepo] = []
        do {
            for page in 1...10 {
                guard let url = connection.url("/user/repos?per_page=100&sort=pushed&affiliation=owner,collaborator,organization_member&page=\(page)") else { break }
                let (data, _) = try await connection.send(URLRequest(url: url), service: "GitHub")
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
        [
            "login": .string(viewer),
            "repos": .array(repos.map { .string($0) }),
            "apiURL": .string(apiURL),
        ]
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
        Task { await verify() }
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

    // MARK: Claude tools

    private struct GetInput: Decodable { let path: String }

    static let maxToolCharacters = 100_000

    var tools: [ClaudeTool] {
        [
            ClaudeTool(
                name: "github_api_get",
                description: "Read any GitHub REST endpoint as the user (GET only), e.g. /repos/owner/name/actions/runs?per_page=10. Use when no more specific GitHub tool fits. Large responses are cut at 100,000 characters.",
                properties: ["path": JSONSchema.string("Path and query after the API root, starting with /.")], required: ["path"]
            ) { [weak self] input in
                guard let self else { return nil }
                let path = try GitHubAPI.validatedPath(try input.toolInput(GetInput.self).path)
                let json = try await api.get(path)
                let text = json.jsonString()
                return text.count > Self.maxToolCharacters
                    ? ["truncated": true, "json": .string(String(text.prefix(Self.maxToolCharacters)))] : json
            },
        ]
    }
}
