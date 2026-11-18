import DashKit
import DashKitTesting
import Foundation
import Testing

/// Fetch, then read: each fetcher calls GitLab and stores a sanitized answer with a receipt; each
/// reader answers from the store with its freshness, or says what to fetch. No tool Dashii or an
/// agent gets calls GitLab. Nested in the serialized suite: both use the shared URL stub.
extension GitLabIntegrationTests {
    @MainActor
    @Suite
    struct Fetch {
        let defaults: UserDefaults

        init() {
            let suite = "GitLabFetchTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            defaults.set("acme/api", forKey: "gitlab.projects")
        }

        static let tags: [String: StubURLProtocol.Reply] = [
            "/api/v4/projects/acme%2Fapi": .json(#"{"default_branch":"main"}"#),
            "/api/v4/projects/acme%2Fapi/repository/tags": .json(#"""
                [{"name":"v1","message":"","created_at":null,"commit":{"id":"aaa","committed_date":"2026-10-01T10:00:00Z","title":"Ship v1"}}]
                """#),
            "/api/v4/projects/acme%2Fapi/repository/merge_base": .json(#"{"id":"aaa"}"#),
            "/api/v4/projects/acme%2Fapi/repository/compare": .json(#"""
                {"commits":[{"id":"c1","parent_ids":["p"],"author_name":"Ann","authored_date":"2026-10-02T00:00:00Z","title":"KAN-123 fix"}]}
                """#),
        ]

        /// A started integration on the stub, its sign-in check done.
        func hosted(_ replies: [String: StubURLProtocol.Reply]) async throws -> (GitLabIntegration, TestHost) {
            var table = replies
            table["/api/v4/user"] = .json(#"{"username":"jdoe"}"#)
            StubURLProtocol.reset(table)
            let gitlab = GitLabIntegration(defaults: defaults, token: { "glpat-t0ken" }, session: StubURLProtocol.session())
            let dash = try TestHost([gitlab])
            dash.start([gitlab])
            await gitlab.verify()
            return (gitlab, dash)
        }

        /// What went to GitLab besides the sign-in check.
        var sent: [URLRequest] { StubURLProtocol.requests.filter { $0.url?.path() != "/api/v4/user" } }

        @Test func mergeRequestsAreFetchedThenRead() async throws {
            let (_, dash) = try await hosted(["/api/v4/projects/acme%2Fapi/merge_requests": .json(GitLabIntegrationTests.mergeRequest)])
            let before = try #require(try await dash.runTool("gitlab_merge_requests"))
            #expect(before["fetched"] == false && before["refresh"] == ["fetcher": "gitlab.merge_requests", "input": [:]])
            #expect(sent.isEmpty)

            let receipt = try await dash.fetch("gitlab.merge_requests")
            #expect(receipt["stored"] == 1 && receipt["read_with"] == "gitlab_merge_requests {}")
            #expect(sent.count == 1)
            let answer = try #require(try await dash.runTool("gitlab_merge_requests"))
            #expect(answer["items"]?[0]?["title"] == "Fix login" && answer["items"]?[0]?["pipeline"] == "success")
            #expect(answer["stale"] == false && answer["synced_at"]?.string != nil)
            #expect(try await dash.fetch("gitlab.merge_requests")["unchanged"] == 1)
        }

        @Test func apiAnswersAreFetchedThenRead() async throws {
            let (gitlab, dash) = try await hosted(["/api/v4/projects/acme%2Fapi/pipelines": .json(#"[{"id":1,"token":"glpat-abcdefghijklmnopqrst"}]"#)])
            let input: JSONValue = ["path": "/projects/acme%2Fapi/pipelines?per_page=5"]
            #expect(try await dash.runTool("gitlab_api_read", input)?["fetched"] == false)
            _ = try await dash.fetch("gitlab.api", input)
            #expect(sent.last?.url?.absoluteString == "https://gitlab.com/api/v4/projects/acme%2Fapi/pipelines?per_page=5")
            let answer = try #require(try await dash.runTool("gitlab_api_read", input))
            #expect(answer["items"]?[0]?["id"] == 1)
            let stored = dash.testSynced.records(kind: "gitlab.api", scope: gitlab.storeScope)
            #expect(stored.count == 1 && !stored[0].value.jsonString().contains("glpat-abcdefghijklmnopqrst"))
        }

        @Test(arguments: ["projects", "//evil.example.com/x", "https://evil.example.com/x", "/projects/../user", "/projects/./x", "/a b"])
        func apiPathsAreChecked(_ path: String) async throws {
            let (_, dash) = try await hosted([:])
            await #expect(throws: ToolError.self) { try await dash.fetch("gitlab.api", ["path": .string(path)]) }
            await #expect(throws: ToolError.self) { try await dash.runTool("gitlab_api_read", ["path": .string(path)]) }
            #expect(sent.isEmpty)
        }

        @Test func projectsAreChecked() async throws {
            let (_, dash) = try await hosted([:])
            for input in [["project": "../etc"], ["project": "lonely"]] as [JSONValue] {
                await #expect(throws: ToolError.self) { try await dash.fetch("gitlab.merge_requests", input) }
            }
            for repo in ["acme", "acme/../x", "acme/ api", "/acme/api"] {
                await #expect(throws: ToolError.self) { try await dash.fetch("gitlab.tags", ["repo": .string(repo)]) }
                await #expect(throws: ToolError.self) { try await dash.runTool("gitlab_tags", ["repo": .string(repo)]) }
            }
            #expect(sent.isEmpty)
        }

        @Test func tagsAndRangesFillTheReleaseMirror() async throws {
            let (_, dash) = try await hosted(Self.tags)
            #expect(try await dash.runTool("gitlab_tags", ["repo": "acme/api"])?["refresh"] == ["fetcher": "gitlab.tags", "input": ["repo": "acme/api"]])
            let receipt = try await dash.fetch("gitlab.tags", ["repo": "acme/api"])
            #expect(receipt["stored"] == 1 && receipt["keys"] == ["git.tag/v1"])
            let tags = try #require(try await dash.runTool("gitlab_tags", ["repo": "acme/api"]))
            #expect(tags["items"]?[0]?["tag"] == "v1" && tags["items"]?[0]?["on_base"] == true && tags["total"] == 1 && tags["stale"] == false)
            #expect(dash.testSynced.record(kind: "git.tag", scope: "gitlab:acme/api", key: "v1") != nil)

            let range: JSONValue = ["repo": "acme/api", "base": "aaa", "head": "bbb"]
            #expect(try await dash.runTool("gitlab_range", range)?["fetched"] == false)
            #expect(try await dash.fetch("gitlab.range", range)["stored"] == 1)
            let compares = sent.filter { $0.url?.path().hasSuffix("/compare") == true }.count
            #expect(try await dash.runTool("gitlab_range", range)?["items"]?[0]?["subject"] == "KAN-123 fix")
            // A range between two commits never changes: fetched once.
            #expect(try await dash.fetch("gitlab.range", range)["unchanged"] == 1)
            #expect(sent.filter { $0.url?.path().hasSuffix("/compare") == true }.count == compares)
        }

        @Test func readersSayWhenDataIsStale() async throws {
            let (gitlab, dash) = try await hosted(Self.tags.merging(["/api/v4/projects/acme%2Fapi/merge_requests": .json("[]")]) { $1 })
            _ = try await dash.fetch("gitlab.merge_requests")
            _ = try await dash.fetch("gitlab.tags", ["repo": "acme/api"])
            gitlab.now = { .now.addingTimeInterval(6 * 60) }
            #expect(try await dash.runTool("gitlab_merge_requests")?["stale"] == true)
            #expect(try await dash.runTool("gitlab_tags", ["repo": "acme/api"])?["stale"] == false)
            gitlab.now = { .now.addingTimeInterval(11 * 60) }
            #expect(try await dash.runTool("gitlab_tags", ["repo": "acme/api"])?["stale"] == true)
        }

        @Test func noToolDashiiGetsCallsGitLab() async throws {
            let (gitlab, dash) = try await hosted(Self.tags.merging(["/api/v4/projects/acme%2Fapi/merge_requests": .json("[]")]) { $1 })
            let values: [String: JSONValue] = ["repo": "acme/api", "project": "acme/api", "path": "/user", "base": "aaa", "head": "bbb"]
            #expect(await NetworkSentinel.requests(running: gitlab.tools, values: values) == [])
            _ = try await dash.fetch("gitlab.merge_requests")
            _ = try await dash.fetch("gitlab.tags", ["repo": "acme/api"])
            #expect(await NetworkSentinel.requests(running: gitlab.tools, values: values) == [])
        }

        @Test func toolsFetchersAndVerbsLineUp() async throws {
            let (gitlab, _) = try await hosted([:])
            #expect(gitlab.fetchers.map(\.name) == ["gitlab.merge_requests", "gitlab.api", "gitlab.tags", "gitlab.range"])
            #expect(gitlab.tools.filter(\.isForDashii).map(\.name) == ["gitlab_merge_requests", "gitlab_api_read", "gitlab_tags", "gitlab_range"])
            #expect(gitlab.tools.filter(\.callsService).map(\.name) == ["gitlab_sync_tags", "gitlab_sync_compare"])
            #expect(!gitlab.tools.contains { $0.name == "gitlab_api_get" })
            #expect(gitlab.verbs.allSatisfy { verb in gitlab.tools.contains { $0.name == verb.tool } })
            #expect(gitlab.storeScope == "gitlab:gitlab.com")
            gitlab.instanceURL = "https://git.example.com/"
            #expect(gitlab.storeScope == "gitlab:git.example.com")
        }
    }
}
