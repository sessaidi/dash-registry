import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Layer 1 for GitLab (gitlab.com or self-managed): personal access token, instance URL and
/// watched projects. Declarative features send `path` requests relative to `/api/v4`.
@MainActor
@Observable
final class GitLabIntegration: Integration {
    static let defaultInstance = "https://gitlab.com"
    static let urlKey = "gitlab.url"
    static let projectsKey = "gitlab.projects"
    static let maxToolCharacters = 100_000

    let id = "gitlab"
    let name = "GitLab"
    let systemImage = "point.3.connected.trianglepath.dotted"
    let metadata = ExtensionMetadata(version: "1.2.0", summary: "gitlab.com or self-managed: token, instance URL and watched projects.", category: .sourceControl, homepage: "https://github.com/sessaidi/dash", minimumDashKit: "2.0.0")
    let secretKeys = [SecretKey("token", "Personal access token")]
    let secrets: SecretStore? = SecretStore(extensionID: "gitlab", legacy: ["token": "gitlab"])

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let readToken: @MainActor () -> String?
    /// URLSession for requests; nil uses the shared session. Tests inject a stubbed one.
    @ObservationIgnored private let session: URLSession?
    /// The host from `start(host:)`, for the "Features using this integration" section.
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?

    var instanceURL: String { didSet { defaults.set(instanceURL, forKey: Self.urlKey) } }
    /// Watched projects, "group/subgroup/project", one per line.
    var projectsText: String { didSet { defaults.set(projectsText, forKey: Self.projectsKey); publishProjects() } }
    private(set) var hasToken: Bool
    private(set) var username = ""
    private(set) var lastError: String?

    /// `token` and `session` exist for tests; the app uses the Keychain and the shared session.
    init(defaults: UserDefaults = DashStorage.defaults, token: (@MainActor () -> String?)? = nil, session: URLSession? = nil) {
        let store = SecretStore(extensionID: "gitlab", legacy: ["token": "gitlab"])
        let readToken = token ?? { store.read("token") }
        self.defaults = defaults
        self.readToken = readToken
        self.session = session
        instanceURL = defaults.string(forKey: Self.urlKey) ?? Self.defaultInstance
        projectsText = defaults.string(forKey: Self.projectsKey) ?? ""
        hasToken = !(readToken() ?? "").isEmpty
    }

    private var token: String? { readToken().flatMap { $0.isEmpty ? nil : $0 } }

    var isConnected: Bool { connection != nil }
    var connectionState: ConnectionState { state(error: lastError, configured: isConnected, account: username.isEmpty ? nil : username) }

    /// What features may read: the instance, the watched projects and who is signed in.
    var exports: JSONValue {
        ["instance": .string(instanceURL), "projects": .array(projects.map { .string($0) }), "login": .string(username)]
    }

    var projects: [String] {
        projectsText.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.contains("/") }
    }

    var connection: IntegrationConnection? {
        guard let token, let base = URL(string: instanceURL), base.scheme == "https",
              let api = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v4") else { return nil }
        return IntegrationConnection(baseURL: api, headers: ["PRIVATE-TOKEN": token, "Accept": "application/json"], session: session)
    }

    func setToken(_ token: String) {
        secrets?.write("token", token)
        hasToken = !token.isEmpty
        username = ""
        Task { await verify() }
    }

    func start(host: any ExtensionContext) {
        self.host = host
        publishProjects()
        Task { await verify() }
    }

    /// The watched projects, in Dash's database for other extensions (Knowledge indexes them).
    func publishProjects() {
        guard let host else { return }
        let site = instanceURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        WatchedRepositories.publish(projects, provider: "gitlab", web: site.isEmpty ? "https://gitlab.com" : site, in: host.synced)
    }

    /// GET a REST path under /api/v4.
    func get(_ path: String) async throws -> JSONValue {
        guard let connection, let url = connection.url(path) else { throw ToolError("Connect GitLab in Settings › GitLab.") }
        let (data, _) = try await connection.send(URLRequest(url: url), service: "GitLab")
        return try JSONValue.parse(data)
    }

    func verify() async {
        guard connection != nil else { return }
        do {
            username = try await get("/user")["username"]?.string ?? ""
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "group/project" -> "group%2Fproject", as GitLab's :id path parameter accepts.
    nonisolated static func projectID(_ path: String) -> String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path
    }

    func prepare(host: any ExtensionContext) async throws {
        guard connection != nil else { return }
        await verify()
        if let lastError { throw ToolError(lastError) }
    }

    func settingsView() -> AnyView { AnyView(GitLabSettingsView(gitlab: self)) }
}
