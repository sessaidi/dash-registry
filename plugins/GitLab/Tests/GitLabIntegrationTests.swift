import DashKit
import DashKitUI
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct GitLabIntegrationTests {
    let defaults: UserDefaults

    init() {
        let suite = "GitLabPluginTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func make(token: String? = "glpat-t0ken", instance: String? = nil, projects: String? = nil) -> GitLabIntegration {
        if let instance { defaults.set(instance, forKey: "gitlab.url") }
        if let projects { defaults.set(projects, forKey: "gitlab.projects") }
        return GitLabIntegration(defaults: defaults, token: { token }, session: StubURLProtocol.session())
    }

    func tool(_ gitlab: GitLabIntegration, _ name: String) throws -> ClaudeTool {
        try #require(gitlab.tools.first { $0.name == name })
    }

    // MARK: Release sync

    @Test func syncTagsMirrorsTagsWithTheirBranch() async throws {
        StubURLProtocol.reset([
            "/api/v4/projects/acme%2Fapi": .json(#"{"default_branch":"main"}"#),
            "/api/v4/projects/acme%2Fapi/repository/tags": .json(#"""
                [{"name":"v1","message":"","created_at":null,"commit":{"id":"aaa","committed_date":"2026-10-01T10:00:00Z","title":"Ship v1"}}]
                """#),
            "/api/v4/projects/acme%2Fapi/repository/merge_base": .json(#"{"id":"aaa"}"#),
        ])
        let gitlab = make()
        let store = MemorySyncedStore()
        #expect(try await gitlab.syncTags("acme/api", store: store) == 1)
        #expect(store.record(kind: "git.tag", scope: "gitlab:acme/api", key: "v1")?.value
                == ["commit": "aaa", "date": "2026-10-01T10:00:00Z", "subject": "Ship v1", "on_base": true])
        #expect(store.record(kind: "git.repo", scope: "gitlab:acme/api", key: "info")?.value["default_branch"] == "main")
    }

    @Test func syncRangeSkipsMergesAndIsCached() async throws {
        StubURLProtocol.reset([
            "/api/v4/projects/acme%2Fapi/repository/compare": .json(#"""
                {"commits":[{"id":"c1","parent_ids":["p"],"author_name":"Ann","authored_date":"2026-10-02T00:00:00Z","title":"Fix bug"},
                            {"id":"m1","parent_ids":["p","q"],"author_name":"Bot","authored_date":"2026-10-02T01:00:00Z","title":"Merge"}]}
                """#),
        ])
        let gitlab = make()
        let store = MemorySyncedStore()
        #expect(try await gitlab.syncRange("acme/api", base: "aaa", head: "bbb", store: store)
                == [["sha": "c1", "author": "Ann", "date": "2026-10-02T00:00:00Z", "subject": "Fix bug"]])
        let before = StubURLProtocol.requests.count
        _ = try await gitlab.syncRange("acme/api", base: "aaa", head: "bbb", store: store)
        #expect(StubURLProtocol.requests.count == before)
    }

    // MARK: Identity

    @Test func identityAndMetadata() {
        let gitlab = make()
        #expect(gitlab.id == "gitlab")
        #expect(gitlab.name == "GitLab")
        #expect(gitlab.layer == .integration)
        #expect(gitlab.metadata.version == "1.2.0")
        #expect(gitlab.metadata.category == .sourceControl)
        #expect(gitlab.metadata.homepage == "https://github.com/sessaidi/dash")
        #expect(gitlab.secrets?.extensionID == "gitlab")
        #expect(gitlab.secrets?.legacy == ["token": "gitlab"])
        #expect(gitlab.secretKeys.map(\.key) == ["token"])
        #expect(gitlab.tools.map(\.name) == ["gitlab_merge_requests", "gitlab_api_get", "gitlab_sync_tags", "gitlab_sync_compare"])
    }

    @Test func pluginEntryPoint() {
        let extensions = GitLabPlugin.makeExtensions()
        #expect(extensions.map(\.id) == ["gitlab"])
        #expect(NSStringFromClass(GitLabPlugin.self) == "GitLabDashPlugin")
    }

    // MARK: Connection

    @Test func connectionHeadersAndBaseURL() throws {
        let connection = try #require(make().connection)
        #expect(connection.baseURL.absoluteString == "https://gitlab.com/api/v4")
        #expect(connection.headers == ["PRIVATE-TOKEN": "glpat-t0ken", "Accept": "application/json"])
    }

    @Test func connectionUsesSelfManagedInstance() throws {
        let connection = try #require(make(instance: "https://git.example.com/").connection)
        #expect(connection.url("/projects")?.absoluteString == "https://git.example.com/api/v4/projects")
    }

    @Test func noConnectionWithoutTokenOrHTTPS() {
        #expect(make(token: nil).connection == nil)
        #expect(make(token: "").connection == nil)
        #expect(make(instance: "http://git.example.com").connection == nil)
        #expect(make(token: nil).isConnected == false)
        #expect(make(token: nil).hasToken == false)
        #expect(make(token: nil).connectionState == .notConfigured)
    }

    @Test func projectIDsAreEncoded() {
        #expect(GitLabIntegration.projectID("group/sub/service") == "group%2Fsub%2Fservice")
    }

    // MARK: Storage

    @Test func preferencesUseLegacyKeys() {
        let gitlab = make()
        #expect(gitlab.instanceURL == "https://gitlab.com")
        gitlab.instanceURL = "https://git.example.com"
        gitlab.projectsText = "acme/api"
        #expect(defaults.string(forKey: "gitlab.url") == "https://git.example.com")
        #expect(defaults.string(forKey: "gitlab.projects") == "acme/api")
        let reloaded = GitLabIntegration(defaults: defaults, token: { nil })
        #expect(reloaded.instanceURL == "https://git.example.com")
        #expect(reloaded.projects == ["acme/api"])
    }

    @Test func projectsNeedASlash() {
        #expect(make(projects: "acme/api\n  group/sub/web  \nlonely\n\n").projects == ["acme/api", "group/sub/web"])
    }

    // MARK: Verification

    @Test func verifyLearnsUsername() async {
        StubURLProtocol.reset(["/api/v4/user": .json(#"{"username":"jdoe","id":7}"#)])
        let gitlab = make()
        await gitlab.verify()
        #expect(gitlab.username == "jdoe")
        #expect(gitlab.connectionState == .connected("Signed in as jdoe"))
        #expect(StubURLProtocol.requests.last?.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "glpat-t0ken")
    }

    @Test func verifyReportsRejectedToken() async throws {
        StubURLProtocol.reset(["/api/v4/user": .json(#"{"message":"401 Unauthorized"}"#, status: 401)])
        let gitlab = make()
        await gitlab.verify()
        guard case .failed = gitlab.connectionState else { Issue.record("expected failure"); return }
        await #expect(throws: ToolError.self) { try await gitlab.prepare(host: FakeHost([])) }
    }

    @Test func verifyWithoutTokenSendsNothing() async throws {
        StubURLProtocol.reset([:])
        let gitlab = make(token: nil)
        await gitlab.verify()
        try await gitlab.prepare(host: FakeHost([]))
        #expect(StubURLProtocol.requests.isEmpty)
        #expect(gitlab.lastError == nil)
    }

    // MARK: gitlab_merge_requests

    static let mergeRequest = """
        [{"references":{"full":"acme/api!12"},"title":"Fix login","author":{"username":"jdoe"},"draft":false,
          "updated_at":"2026-11-01T10:00:00Z","web_url":"https://gitlab.com/acme/api/-/merge_requests/12","head_pipeline":{"status":"success"},"extra":1}]
        """

    @Test func mergeRequestsForEveryWatchedProject() async throws {
        StubURLProtocol.reset([
            "/api/v4/projects/acme%2Fapi/merge_requests": .json(Self.mergeRequest),
            "/api/v4/projects/acme%2Fweb/merge_requests": .json("[]"),
        ])
        let gitlab = make(projects: "acme/api\nacme/web")
        let result = try await tool(gitlab, "gitlab_merge_requests").run([:])
        #expect(result == [[
            "project": "acme/api!12", "title": "Fix login", "author": "jdoe", "draft": false,
            "updated_at": "2026-11-01T10:00:00Z", "url": "https://gitlab.com/acme/api/-/merge_requests/12", "pipeline": "success",
        ]])
        #expect(StubURLProtocol.requests.map { $0.url?.query() } == ["state=opened&per_page=50", "state=opened&per_page=50"])
    }

    @Test func mergeRequestsInstanceWideByScope() async throws {
        StubURLProtocol.reset(["/api/v4/merge_requests": .json("[]")])
        let gitlab = make(projects: "acme/api")
        #expect(try await tool(gitlab, "gitlab_merge_requests").run(["scope": "assigned_to_me"]) == [])
        let sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.url?.absoluteString == "https://gitlab.com/api/v4/merge_requests?state=opened&scope=assigned_to_me&per_page=50")
    }

    @Test func mergeRequestsForOneProject() async throws {
        StubURLProtocol.reset(["/api/v4/projects/group%2Fsub%2Fsvc/merge_requests": .json("[]")])
        let gitlab = make(projects: "acme/api")
        _ = try await tool(gitlab, "gitlab_merge_requests").run(["project": "group/sub/svc", "scope": "all"])
        #expect(StubURLProtocol.requests.count == 1)
    }

    // MARK: gitlab_api_get

    @Test func apiGetReturnsJSON() async throws {
        StubURLProtocol.reset(["/api/v4/projects/acme%2Fapi/pipelines": .json(#"[{"id":1}]"#)])
        let gitlab = make()
        let result = try await tool(gitlab, "gitlab_api_get").run(["path": "/projects/acme%2Fapi/pipelines?per_page=5"])
        #expect(result == [["id": 1]])
        #expect(StubURLProtocol.requests.last?.url?.absoluteString == "https://gitlab.com/api/v4/projects/acme%2Fapi/pipelines?per_page=5")
    }

    @Test func apiGetNeedsLeadingSlash() async throws {
        StubURLProtocol.reset([:])
        let gitlab = make()
        await #expect(throws: ToolError("path must start with /")) { try await tool(gitlab, "gitlab_api_get").run(["path": "projects"]) }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func apiGetNeedsConnection() async throws {
        let gitlab = make(token: nil)
        await #expect(throws: ToolError("Connect GitLab in Settings › GitLab.")) {
            try await tool(gitlab, "gitlab_api_get").run(["path": "/user"])
        }
    }

    @Test func apiGetTruncatesLargeResponses() async throws {
        let big = String(repeating: "a", count: 120_000)
        StubURLProtocol.reset(["/api/v4/big": .json("{\"blob\":\"\(big)\"}")])
        let gitlab = make()
        let result = try await tool(gitlab, "gitlab_api_get").run(["path": "/big"])
        #expect(result["truncated"] == true)
        #expect(result["json"]?.string?.count == GitLabIntegration.maxToolCharacters)
    }

    // MARK: Settings

    @Test func featuresUsingListsDependents() {
        let gitlab = make(token: nil)
        let host = FakeHost([gitlab, FakeFeature("mrs", requires: ["gitlab"]), FakeFeature("ci", optional: ["gitlab"]), FakeFeature("jira", requires: ["atlassian"])])
        gitlab.start(host: host)
        #expect(gitlab.host === host)
        #expect(FeaturesUsingSection.features(using: "gitlab", in: host.extensions).map(\.id) == ["mrs", "ci"])
        _ = gitlab.settingsView()
    }
}
