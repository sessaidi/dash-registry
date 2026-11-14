import DashKit
import DashKitUI
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct GitHubIntegrationTests {
    let defaults: UserDefaults

    init() {
        let suite = "GitHubPluginTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
    }

    func make(token: String? = "t0ken", api: String? = nil, repos: String? = nil) -> GitHubIntegration {
        if let api { defaults.set(api, forKey: "github.api") }
        if let repos { defaults.set(repos, forKey: "github.repos") }
        return GitHubIntegration(defaults: defaults, token: { token }, session: StubURLProtocol.session())
    }

    func tool(_ github: GitHubIntegration) throws -> ClaudeTool {
        try #require(github.tools.first { $0.name == "github_api_get" })
    }

    // MARK: Identity

    @Test func identityAndMetadata() {
        let github = make()
        #expect(github.id == "github")
        #expect(github.layer == .integration)
        #expect(github.metadata.version == "1.1.0")
        #expect(github.metadata.category == .sourceControl)
        #expect(github.metadata.author == .dash)
        #expect(github.metadata.homepage == "https://github.com/sessaidi/dash")
        #expect(github.secrets?.extensionID == "github")
        #expect(github.secrets?.legacy == ["token": "github"])
        #expect(github.secretKeys.map(\.key) == ["token"])
    }

    @Test func pluginEntryPoint() {
        let extensions = GitHubPlugin.makeExtensions()
        #expect(extensions.map(\.id) == ["github"])
        #expect(NSStringFromClass(GitHubPlugin.self) == "GitHubDashPlugin")
    }

    // MARK: Connection

    @Test func connectionHeadersAndBaseURL() async throws {
        StubURLProtocol.reset(["/user": .json(#"{"login":"octocat"}"#)])
        let github = make()
        let connection = try #require(github.connection)
        #expect(connection.baseURL.absoluteString == "https://api.github.com")
        #expect(connection.headers == [
            "Authorization": "Bearer t0ken",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        ])

        _ = try await connection.get("/user", service: "GitHub")
        let sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.url?.absoluteString == "https://api.github.com/user")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(sent.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
    }

    @Test func connectionUsesEnterpriseAPIURL() throws {
        let github = make(api: "https://ghe.example.com/api/v3")
        let connection = try #require(github.connection)
        #expect(connection.url("/repos/a/b")?.absoluteString == "https://ghe.example.com/api/v3/repos/a/b")
    }

    @Test func noConnectionWithoutTokenOrValidURL() {
        #expect(make(token: nil).connection == nil)
        #expect(make(token: "").connection == nil)
        #expect(make(api: "not a url").connection == nil)
        #expect(make(token: nil).isConnected == false)
        #expect(make(token: nil).connectionState == .notConfigured)
    }

    // MARK: Exports and storage

    @Test func exportsLoginReposAndAPIURL() async {
        StubURLProtocol.reset(["/user": .json(#"{"login":"octocat","id":1}"#)])
        let github = make(repos: "acme/api\n  acme/web , bad-entry\n/missing\nowner/\n")
        #expect(await github.verify())
        #expect(github.exports == [
            "login": "octocat",
            "repos": ["acme/api", "acme/web"],
            "apiURL": "https://api.github.com",
        ])
    }

    @Test func preferencesUseLegacyKeys() {
        let github = make()
        github.apiURL = "https://ghe.example.com/api/v3"
        github.reposText = "acme/api"
        #expect(defaults.string(forKey: "github.api") == "https://ghe.example.com/api/v3")
        #expect(defaults.string(forKey: "github.repos") == "acme/api")
        let reloaded = GitHubIntegration(defaults: defaults, token: { nil })
        #expect(reloaded.apiURL == "https://ghe.example.com/api/v3")
        #expect(reloaded.repos == ["acme/api"])
    }

    // MARK: Viewer verification

    @Test func verifyLearnsViewer() async throws {
        StubURLProtocol.reset(["/user": .json(#"{"login":"octocat","name":"The Octocat"}"#)])
        let github = make()
        #expect(await github.verify())
        #expect(github.viewer == "octocat")
        #expect(github.connectionState == .connected("Signed in as octocat"))
        #expect(try await github.ensureViewer() == "octocat")
    }

    @Test func verifyReportsRejectedToken() async {
        StubURLProtocol.reset(["/user": .json(#"{"message":"Bad credentials"}"#, status: 401)])
        let github = make()
        #expect(await github.verify() == false)
        #expect(github.viewer.isEmpty)
        #expect(github.connectionState == .failed("GitHub rejected the credentials (401). Check the token in Settings."))
    }

    @Test func verifyRejectsResponseWithoutLogin() async {
        StubURLProtocol.reset(["/user": .json(#"{"id":1}"#)])
        let github = make()
        #expect(await github.verify() == false)
        guard case .failed = github.connectionState else { Issue.record("expected failure"); return }
    }

    @Test func verifyWithoutTokenSendsNothing() async {
        StubURLProtocol.reset([:])
        let github = make(token: nil)
        #expect(await github.verify() == false)
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func loginParsing() throws {
        #expect(try GitHubAPI.login(from: ["login": "octocat"]) == "octocat")
        #expect(throws: ToolError.self) { try GitHubAPI.login(from: ["login": ""]) }
        #expect(throws: ToolError.self) { try GitHubAPI.login(from: .array([])) }
    }

    // MARK: github_api_get

    @Test func toolReturnsJSON() async throws {
        StubURLProtocol.reset(["/repos/acme/api/actions/runs": .json(#"{"total_count":2}"#)])
        let github = make()
        let result = try await tool(github).run(["path": "/repos/acme/api/actions/runs?per_page=10"])
        #expect(result == ["total_count": 2])
        let sent = try #require(StubURLProtocol.requests.last)
        #expect(sent.httpMethod == "GET")
        #expect(sent.url?.absoluteString == "https://api.github.com/repos/acme/api/actions/runs?per_page=10")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken")
    }

    @Test(arguments: [
        "repos/acme/api", "", "https://evil.example.com/x", "//evil.example.com/x",
        "/repos/../user", "/repos/./x", "/repos/acme api",
    ])
    func toolRejectsBadPaths(path: String) async throws {
        StubURLProtocol.reset([:])
        let github = make()
        await #expect(throws: ToolError.self) { try await tool(github).run(["path": .string(path)]) }
        #expect(StubURLProtocol.requests.isEmpty)
    }

    @Test func toolRequiresPathField() async throws {
        let github = make()
        await #expect(throws: ToolError.self) { try await tool(github).run(["route": "/user"]) }
    }

    @Test func toolRequiresToken() async throws {
        let github = make(token: nil)
        await #expect(throws: ToolError("Connect GitHub in the Extensions window.")) {
            try await tool(github).run(["path": "/user"])
        }
    }

    @Test func toolTruncatesLargeResponses() async throws {
        let big = String(repeating: "a", count: 120_000)
        StubURLProtocol.reset(["/big": .json("{\"blob\":\"\(big)\"}")])
        let github = make()
        let result = try await tool(github).run(["path": "/big"])
        #expect(result["truncated"] == true)
        #expect(result["json"]?.string?.count == GitHubIntegration.maxToolCharacters)
    }

    @Test func validPathsPassThrough() throws {
        #expect(try GitHubAPI.validatedPath(" /repos/acme/api/pulls?state=open ") == "/repos/acme/api/pulls?state=open")
        #expect(try GitHubAPI.validatedPath("/search/issues?q=is:pr+author:me") == "/search/issues?q=is:pr+author:me")
        #expect(try GitHubAPI.validatedPath("/x?u=https://example.com") == "/x?u=https://example.com")
    }
}

@Suite("GitHub read tools")
struct GitHubReadToolTests {
    @MainActor @Test func toolsAreAllReadOnly() {
        let names = GitHubIntegration(defaults: UserDefaults(suiteName: "gh-\(UUID())")!).tools.map(\.name)
        #expect(names.count >= 18)
        #expect(names.contains("github_workflow_runs") && names.contains("github_job_log") && names.contains("github_pull_reviews"))
        #expect(GitHubIntegration(defaults: UserDefaults(suiteName: "gh-\(UUID())")!).tools.allSatisfy { !$0.requiresApproval })
    }

    @Test func compactShapes() throws {
        let pr: JSONValue = ["number": 7, "title": "Retries", "user": ["login": "ada"], "state": "open", "draft": false, "merged_at": .null,
                             "head": ["ref": "feature/x"], "base": ["ref": "main"], "labels": [["name": "backend"]], "requested_reviewers": [["login": "bob"]]]
        let summary = GitHubIntegration.pullSummary(pr)
        #expect(summary["author"] == "ada" && summary["head"] == "feature/x" && summary["labels"] == ["backend"] && summary["requested_reviewers"] == ["bob"])
        let job: JSONValue = ["id": 1, "name": "test", "conclusion": "failure", "steps": [["name": "Build", "conclusion": "success"], ["name": "Unit tests", "conclusion": "failure"]]]
        #expect(GitHubIntegration.jobSummary(job)["failed_steps"] == ["Unit tests"])
        #expect(try GitHubIntegration.repoPath(["repo": "fubotv/services-user"]) == "/repos/fubotv/services-user")
        #expect(throws: ToolError.self) { try GitHubIntegration.repoPath(["repo": "../etc"]) }
        #expect(GitHubIntegration.query([("state", "open"), ("base", nil), ("q", "is:pr is:open")]) == "?state=open&q=is%3Apr%20is%3Aopen")
    }
}
