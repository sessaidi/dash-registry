import DashKit
import DashKitTesting
import Foundation
import Testing

/// Fetch, then read: each fetcher calls GitHub and stores a sanitized answer with a receipt; each
/// reader answers from the store with its freshness, or says what to fetch. No tool Dashii or an
/// agent gets makes a request. Every test has its own stub host.
@MainActor
struct GitHubFetchTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let fetcher: String
        let input: JSONValue
        let routes: [String: String]
        /// A request the fetch must make.
        let path: String
        let check: @Sendable (JSONValue) -> Bool
        var testDescription: String { fetcher }
    }

    nonisolated static let repo = "/repos/acme/billing-api"
    nonisolated static let pr = #"""
        {"number":7,"title":"Retries","user":{"login":"ada"},"state":"open","draft":false,"merged_at":null,"head":{"ref":"feature/x"},
         "base":{"ref":"main"},"labels":[{"name":"backend"}],"requested_reviewers":[],"updated_at":"2026-11-17T09:00:00Z",
         "html_url":"https://github.com/acme/billing-api/pull/7","body":"Set GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789 locally"}
        """#

    nonisolated static let cases: [Case] = [
        Case(fetcher: "github.whoami", input: [:], routes: ["/user": #"{"login":"octocat","name":"Octo"}"#, "/user/orgs": #"[{"login":"acme"}]"#],
             path: "/user/orgs") { $0["login"] == "octocat" && $0["organizations"] == ["acme"] },
        Case(fetcher: "github.repo", input: ["repo": "acme/billing-api"], routes: [repo: #"{"full_name":"acme/billing-api","default_branch":"main","private":true}"#],
             path: repo) { $0["name"] == "acme/billing-api" && $0["default_branch"] == "main" },
        Case(fetcher: "github.branches", input: ["repo": "acme/billing-api"], routes: [repo + "/branches": #"[{"name":"main","commit":{"sha":"abcdef123456"},"protected":true}]"#],
             path: repo + "/branches") { $0["items"]?[0]?["sha"] == "abcdef1" },
        Case(fetcher: "github.pulls", input: ["repo": "acme/billing-api"], routes: [repo + "/pulls": "[\(pr)]"],
             path: repo + "/pulls") { $0["items"]?[0]?["number"] == 7 && $0["items"]?[0]?["author"] == "ada" },
        Case(fetcher: "github.pull", input: ["repo": "acme/billing-api", "number": 7], routes: [repo + "/pulls/7": pr],
             path: repo + "/pulls/7") { $0["title"] == "Retries" && $0["body"]?.string?.contains("ghp_") == false },
        Case(fetcher: "github.pull_files", input: ["repo": "acme/billing-api", "number": 7],
             routes: [repo + "/pulls/7/files": #"[{"filename":"retry.go","status":"modified","additions":3,"deletions":1}]"#],
             path: repo + "/pulls/7/files") { $0["items"]?[0]?["file"] == "retry.go" },
        Case(fetcher: "github.pull_reviews", input: ["repo": "acme/billing-api", "number": 7],
             routes: [repo + "/pulls/7/reviews": #"[{"user":{"login":"bob"},"state":"APPROVED","body":"ok"}]"#, repo + "/pulls/7/comments": "[]"],
             path: repo + "/pulls/7/reviews") { $0["reviews"]?[0]?["by"] == "bob" && $0["line_comments"] == [] },
        Case(fetcher: "github.checks", input: ["repo": "acme/billing-api", "ref": "main"],
             routes: [repo + "/commits/main/check-runs": #"{"check_runs":[{"name":"test","status":"completed","conclusion":"failure"}]}"#,
                      repo + "/commits/main/status": #"{"state":"failure","statuses":[]}"#],
             path: repo + "/commits/main/check-runs") { $0["state"] == "failure" && $0["checks"]?[0]?["conclusion"] == "failure" },
        Case(fetcher: "github.workflow_runs", input: ["repo": "acme/billing-api"],
             routes: [repo + "/actions/runs": #"{"workflow_runs":[{"id":11,"name":"CI","head_branch":"main","head_sha":"abcdef9999","status":"completed","conclusion":"failure"}]}"#],
             path: repo + "/actions/runs") { $0["items"]?[0]?["id"] == 11 && $0["items"]?[0]?["sha"] == "abcdef9" },
        Case(fetcher: "github.run_jobs", input: ["repo": "acme/billing-api", "run_id": 11],
             routes: [repo + "/actions/runs/11/jobs": #"{"jobs":[{"id":21,"name":"test","conclusion":"failure","steps":[{"name":"Unit","conclusion":"failure"}]}]}"#],
             path: repo + "/actions/runs/11/jobs") { $0["items"]?[0]?["failed_steps"] == ["Unit"] },
        Case(fetcher: "github.job_log", input: ["repo": "acme/billing-api", "job_id": 21], routes: [repo + "/actions/jobs/21/logs": "setup\nrun\nerror: boom"],
             path: repo + "/actions/jobs/21/logs") { $0["text"]?.string?.hasSuffix("error: boom") == true },
        Case(fetcher: "github.commits", input: ["repo": "acme/billing-api"],
             routes: [repo + "/commits": #"[{"sha":"abcdef1234","commit":{"author":{"name":"Ann","date":"2026-11-16T10:00:00Z"},"message":"Fix retries\n\nbody"}}]"#],
             path: repo + "/commits") { $0["items"]?[0]?["message"] == "Fix retries" },
        Case(fetcher: "github.compare", input: ["repo": "acme/billing-api", "base": "v1", "head": "v2"],
             routes: [repo + "/compare/v1...v2": #"{"status":"ahead","ahead_by":2,"behind_by":0,"commits":[],"files":[{"filename":"a.go","status":"added"}]}"#],
             path: repo + "/compare/v1...v2") { $0["ahead_by"] == 2 && $0["files"]?[0]?["file"] == "a.go" },
        Case(fetcher: "github.file", input: ["repo": "acme/billing-api", "path": "README.md"],
             routes: [repo + "/contents/README.md": #"{"path":"README.md","size":5,"content":"aGVsbG8="}"#],
             path: repo + "/contents/README.md") { $0["content"] == "hello" },
        Case(fetcher: "github.issues", input: ["repo": "acme/billing-api"],
             routes: [repo + "/issues": #"[{"number":3,"title":"Bug","user":{"login":"ann"},"state":"open"},{"number":4,"pull_request":{}}]"#],
             path: repo + "/issues") { $0["items"]?.array?.count == 1 && $0["items"]?[0]?["number"] == 3 },
        Case(fetcher: "github.releases", input: ["repo": "acme/billing-api"],
             routes: [repo + "/releases": #"[{"tag_name":"v1.2.0","name":"1.2","published_at":"2026-11-10T00:00:00Z","body":"notes"}]"#],
             path: repo + "/releases") { $0["items"]?[0]?["tag"] == "v1.2.0" },
        Case(fetcher: "github.search", input: ["kind": "issues", "query": "is:pr is:open"],
             routes: ["/search/issues": #"{"total_count":1,"items":[{"title":"Retries","number":7,"state":"open","pull_request":{},"user":{"login":"ada"}}]}"#],
             path: "/search/issues") { $0["total"] == 1 && $0["items"]?[0]?["pr"] == true },
        Case(fetcher: "github.notifications", input: [:],
             routes: ["/notifications": #"[{"repository":{"full_name":"acme/billing-api"},"reason":"review_requested","subject":{"title":"Retries","type":"PullRequest"}}]"#],
             path: "/notifications") { $0["items"]?[0]?["reason"] == "review_requested" },
        Case(fetcher: "github.api", input: ["path": "/repos/acme/billing-api/actions/runs?per_page=10"], routes: [repo + "/actions/runs": #"{"total_count":2}"#],
             path: repo + "/actions/runs") { $0["total_count"] == 2 },
    ]

    let stub = "gh-\(UUID().uuidString.prefix(8).lowercased()).test"
    let dash: TestHost
    let github: GitHubIntegration

    init() throws {
        let defaults = UserDefaults(suiteName: "gh-fetch-\(UUID())")!
        defaults.set("https://\(stub)", forKey: "github.api")
        github = GitHubIntegration(defaults: defaults, token: { "t0ken" }, session: StubHTTP.session)
        dash = try TestHost([github])
        dash.start([github])
    }

    func serve(_ routes: [String: String]) {
        StubHTTP.serve(stub, routes: routes.merging(["/user": #"{"login":"octocat"}"#]) { mine, _ in mine })
    }

    func resource(_ fetcher: String) throws -> GitHubResource {
        try #require(github.resources.first { $0.fetcherName == fetcher })
    }

    // MARK: Fetchers and readers

    @Test(arguments: cases)
    func fetcherStoresAndReaderReads(_ c: Case) async throws {
        serve(c.routes)
        let resource = try resource(c.fetcher)

        let before = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(before["fetched"] == false && before["rows"] == [])
        #expect(before["refresh"]?["fetcher"] == .string(c.fetcher))

        let receipt = try await dash.fetch(c.fetcher, c.input)
        #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0)
        #expect(receipt["keys"]?.array?.count == 1 && receipt["keys"]?[0]?.string?.hasPrefix(resource.kind + "/") == true)
        #expect(receipt["synced_at"]?.string != nil)
        #expect(receipt["read_with"]?.string?.hasPrefix(resource.readerName + " {") == true)
        let sent = StubHTTP.requests(stub)
        #expect(sent.contains { $0.url?.path() == c.path })
        #expect(sent.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer t0ken" })

        let answer = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(c.check(answer), "\(answer.jsonString())")
        #expect(answer["stale"] == false && answer["synced_at"]?.string != nil)
        #expect(answer["refresh"]?["fetcher"] == .string(c.fetcher))

        let again = try await dash.fetch(c.fetcher, c.input)
        #expect(again["stored"] == 0 && again["unchanged"] == 1)
        let stored = dash.testSynced.records(kind: resource.kind, scope: github.storeScope)
        #expect(stored.count == 1)
        #expect(stored.allSatisfy { !$0.value.jsonString().contains("ghp_") && $0.source == "github" })
    }

    @Test func readersSayWhenDataIsStale() async throws {
        serve([Self.repo + "/pulls": "[\(Self.pr)]"])
        _ = try await dash.fetch("github.pulls", ["repo": "acme/billing-api"])
        github.freshMinutes = 15
        github.now = { .now.addingTimeInterval(16 * 60) }
        let answer = try #require(try await dash.runTool("github_pulls", ["repo": "acme/billing-api"]))
        #expect(answer["stale"] == true && answer["items"]?[0]?["number"] == 7)
        #expect(answer["refresh"] == ["fetcher": "github.pulls", "input": ["repo": "acme/billing-api"]])
    }

    @Test func inputsAreNormalized() async throws {
        serve([Self.repo + "/pulls": "[\(Self.pr)]"])
        _ = try await dash.fetch("github.pulls", ["repo": "acme/billing-api"])
        let answer = try #require(try await dash.runTool("github_pulls", ["repo": " Acme/Billing-API ", "author": "", "extra": 1]))
        #expect(answer.object?.keys.contains("fetched") == false && answer["items"]?[0]?["number"] == 7)
        await #expect(throws: ToolError("Give repo and number.")) { _ = try await dash.runTool("github_pull", [:]) }
        await #expect(throws: ToolError("Give repo as owner/name.")) { _ = try await dash.runTool("github_pulls", ["repo": "../etc"]) }
    }

    @Test func queryAnswersExpireAfterADay() async throws {
        serve([Self.repo + "/pulls": "[\(Self.pr)]"])
        _ = try await dash.fetch("github.pulls", ["repo": "acme/billing-api"])
        github.now = { .now.addingTimeInterval(2 * 86_400) }
        _ = try await dash.fetch("github.pulls", ["repo": "acme/billing-api", "state": "closed"])
        let stored = dash.testSynced.records(kind: "github.pulls", scope: github.storeScope)
        #expect(stored.map { $0.value["input"]?["state"] } == ["closed"])
    }

    @Test func bigAnswersAreCapped() async throws {
        serve([Self.repo + "/actions/runs": "{\"blob\":\"\(String(repeating: "a", count: 300_000))\"}"])
        _ = try await dash.fetch("github.api", ["path": .string(Self.repo + "/actions/runs")])
        let stored = try #require(dash.testSynced.records(kind: "github.api", scope: github.storeScope).first)
        #expect(stored.value["data"]?["truncated"] == true)
        #expect(stored.value.jsonString().utf8.count < 201_000)
        await #expect(throws: ToolError.self) { _ = try await dash.fetch("github.api", ["path": "https://elsewhere.example.com/x"]) }
    }

    @Test func tagsAndRangesForReleases() async throws {
        serve([
            Self.repo: #"{"default_branch":"main"}"#,
            "/graphql": #"""
                {"data":{"repository":{"refs":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
                 {"name":"v1","target":{"__typename":"Commit","oid":"aaa","committedDate":"2026-10-01T10:00:00Z","messageHeadline":"Ship v1"}},
                 {"name":"v2","target":{"__typename":"Commit","oid":"bbb","committedDate":"2026-10-05T10:00:00Z","messageHeadline":"Ship v2"}}]}}}}
                """#,
            Self.repo + "/compare/main...aaa": #"{"status":"behind"}"#,
            Self.repo + "/compare/main...bbb": #"{"status":"identical"}"#,
            Self.repo + "/compare/aaa...bbb": #"{"commits":[{"sha":"c1","parents":[{}],"commit":{"author":{"name":"Ann","date":"2026-10-02T00:00:00Z"},"message":"Fix"}}]}"#,
        ])
        #expect(try await dash.runTool("github_tags", ["repo": "acme/billing-api"])?["fetched"] == false)
        let receipt = try await dash.fetch("github.tags", ["repo": "acme/billing-api"])
        #expect(receipt["stored"] == 2 && receipt["unchanged"] == 0 && receipt["read_with"] == #"github_tags {"repo":"acme/billing-api"}"#)
        let tags = try #require(try await dash.runTool("github_tags", ["repo": "acme/billing-api"]))
        #expect(tags["items"]?.array?.compactMap { $0["tag"]?.string } == ["v2", "v1"] && tags["total"] == 2 && tags["stale"] == false)
        #expect(try await dash.fetch("github.tags", ["repo": "acme/billing-api"])["unchanged"] == 2)
        // Releases reads the same mirror.
        #expect(dash.testSynced.records(kind: "git.tag", scope: "github:acme/billing-api").count == 2)

        let range: JSONValue = ["repo": "acme/billing-api", "base": "aaa", "head": "bbb"]
        #expect(try await dash.runTool("github_range", range)?["fetched"] == false)
        #expect(try await dash.fetch("github.range", range)["stored"] == 1)
        #expect(try await dash.fetch("github.range", range)["unchanged"] == 1)
        let commits = try #require(try await dash.runTool("github_range", range))
        #expect(commits["items"] == [["sha": "c1", "author": "Ann", "date": "2026-10-02T00:00:00Z", "subject": "Fix"]])
    }

    // MARK: No network for Dashii and agents

    @Test func noToolDashiiGetsCallsGitHub() async throws {
        let values: [String: JSONValue] = ["repo": "acme/billing-api", "number": 7, "ref": "main", "base": "aaa", "head": "bbb", "path": "/user"]
        #expect(await NetworkSentinel.requests(running: github.tools, values: values) == [])
        // With data stored, the readers still only read.
        serve([Self.repo + "/pulls": "[\(Self.pr)]", Self.repo + "/pulls/7": Self.pr])
        _ = try await dash.fetch("github.pulls", ["repo": "acme/billing-api"])
        _ = try await dash.fetch("github.pull", ["repo": "acme/billing-api", "number": 7])
        #expect(await NetworkSentinel.requests(running: github.tools, values: values) == [])

        // The tools kept for other extensions do call GitHub: the sentinel would catch them.
        let exposed = github.extensionTools.map { tool in
            var tool = tool
            tool.callsService = false
            return tool
        }
        let caught = await NetworkSentinel.requests(running: exposed, values: values)
        #expect(caught.map { String($0.prefix { $0 != ":" }) } == ["github_api_get", "github_sync_tags", "github_sync_compare"])
    }

    @Test func toolsFetchersAndDatasetsLineUp() throws {
        let tools = github.tools
        let readers = tools.filter(\.isForDashii).map(\.name)
        #expect(Set(github.resources.map(\.readerName)).isSubset(of: readers))
        #expect(readers.contains("github_tags") && readers.contains("github_range") && readers.contains("github_api_read"))
        #expect(tools.filter(\.callsService).map(\.name) == ["github_api_get", "github_sync_tags", "github_sync_compare"])
        #expect(tools.allSatisfy { !$0.requiresApproval && !$0.writesRemotely })
        let fetchers = github.fetchers.map(\.name)
        #expect(fetchers.count == github.resources.count + 2 && fetchers.allSatisfy { $0.hasPrefix("github.") })
        #expect(Set(fetchers).count == fetchers.count && Set(readers).count == readers.count)
        // The DashQL verbs still name tools Dashii gets.
        #expect(github.verbs.allSatisfy { readers.contains($0.tool) })
        #expect(github.datasets.map(\.name) == ["github_pulls", "github_issues", "github_runs", "github_releases"])
    }

    @Test func datasetsReadStoredAnswers() async throws {
        serve([Self.repo + "/pulls": "[\(Self.pr)]", Self.repo + "/pulls/7": Self.pr,
               Self.repo + "/actions/runs": #"{"workflow_runs":[{"id":11,"name":"CI","status":"completed","conclusion":"failure"}]}"#])
        let pulls = try #require(github.datasets.first { $0.name == "github_pulls" })
        #expect(try await pulls.rows(nil).isEmpty)
        _ = try await dash.fetch("github.pulls", ["repo": "acme/billing-api"])
        _ = try await dash.fetch("github.pull", ["repo": "acme/billing-api", "number": 7])
        _ = try await dash.fetch("github.workflow_runs", ["repo": "acme/billing-api", "status": "failure"])
        let rows = try await pulls.rows(nil)
        #expect(rows.count == 1)
        #expect(rows.first?["repo"] == "acme/billing-api" && rows.first?["number"] == 7 && rows.first?["stale"] == false && rows.first?["synced_at"]?.string != nil)
        let runs = try await #require(github.datasets.first { $0.name == "github_runs" }).rows(nil)
        #expect(runs.map { $0["conclusion"] } == ["failure"])
    }
}
