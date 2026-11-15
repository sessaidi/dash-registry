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
    let metadata = ExtensionMetadata(version: "1.2.0", summary: "gitlab.com or self-managed: token, instance URL and watched projects.", category: .sourceControl, homepage: "https://github.com/sessaidi/dash", minimumDashKit: "1.5.0")
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
    var projectsText: String { didSet { defaults.set(projectsText, forKey: Self.projectsKey) } }
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
        Task { await verify() }
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

    // MARK: Claude tools

    private struct GetInput: Decodable { let path: String }
    private struct MRInput: Decodable { let project: String?; let scope: String? }

    var tools: [DashiiTool] {
        [
            DashiiTool(
                name: "gitlab_merge_requests",
                description: "Open merge requests on a GitLab project (default: every watched project), or across the instance for the user with scope assigned_to_me / created_by_me.",
                properties: [
                    "project": JSONSchema.string("Project path, e.g. group/service."),
                    "scope": JSONSchema.string("For instance-wide lists.", enum: ["assigned_to_me", "created_by_me", "all"]),
                ]
            ) { [weak self] input in
                guard let self else { return [] }
                let request = try input.toolInput(MRInput.self)
                var items: [JSONValue] = []
                if let scope = request.scope, request.project == nil {
                    items = try await get("/merge_requests?state=opened&scope=\(scope)&per_page=50").array ?? []
                } else {
                    for project in request.project.map({ [$0] }) ?? projects {
                        items += try await get("/projects/\(Self.projectID(project))/merge_requests?state=opened&per_page=50").array ?? []
                    }
                }
                return .array(items.map {
                    ["project": $0["references"]?["full"] ?? .null, "title": $0["title"] ?? .null, "author": $0["author"]?["username"] ?? .null,
                     "draft": $0["draft"] ?? .null, "updated_at": $0["updated_at"] ?? .null, "url": $0["web_url"] ?? .null,
                     "pipeline": $0["head_pipeline"]?["status"] ?? .null]
                })
            },
            DashiiTool(
                name: "gitlab_api_get",
                description: "Read any GitLab REST v4 endpoint as the user (GET only), e.g. /projects/group%2Fservice/pipelines?per_page=5. Responses are cut at 100,000 characters.",
                properties: ["path": JSONSchema.string("Path after /api/v4, starting with /.")], required: ["path"]
            ) { [weak self] input in
                guard let self else { return nil }
                let path = try input.toolInput(GetInput.self).path
                guard path.hasPrefix("/") else { throw ToolError("path must start with /") }
                let json = try await get(path)
                let text = json.jsonString()
                return text.count > Self.maxToolCharacters
                    ? ["truncated": true, "json": .string(String(text.prefix(Self.maxToolCharacters)))] : json
            },
        ] + syncTools
    }
}
