import DashKit
import DashKitTesting
import Foundation
import Testing

/// Fetch, then read: each fetcher calls Jira or Confluence and stores a sanitized answer with a
/// receipt; each reader answers from the mirror with its freshness, or says what to fetch. No tool
/// Dashii or an agent gets makes a request. Every test has its own site host.
@MainActor
struct AtlassianFetchTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let fetcher: String
        let input: JSONValue
        let routes: [String: String]
        /// A request the fetch must make.
        let path: String
        let check: @Sendable (JSONValue) -> Bool
        var testDescription: String { fetcher }
    }

    nonisolated static let issue = #"{"key":"KAN-12","fields":{"summary":"Fix login","status":{"name":"In Progress"},"issuetype":{"name":"Bug"},"priority":{"name":"High"},"assignee":{"displayName":"Ada"},"reporter":{"displayName":"Bob"},"updated":"2026-11-10T10:00:00.000+0000","labels":["auth"],"description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Users can't sign in. Set "},{"type":"text","text":"DB_PASSWORD=hunter2secret","marks":[{"type":"code"}]}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"iOS"}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"web","marks":[{"type":"strong"}]}]}]}]}]},"subtasks":[{"key":"KAN-13","fields":{"summary":"Test","status":{"name":"To Do"}}}],"issuelinks":[{"type":{"inward":"is blocked by","outward":"blocks"},"inwardIssue":{"key":"CAP-1","fields":{"summary":"Gateway","status":{"name":"Done"}}}}],"comment":{"total":1,"comments":[{"author":{"displayName":"Ada"},"created":"2026-11-10","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"On it"}]}]}}]}}}"#
    nonisolated static let page = #"{"id":"12345","title":"Runbook","space":{"key":"OPS","name":"Ops"},"version":{"number":7,"when":"2026-11-01T10:00:00Z","by":{"displayName":"Ada"}},"_links":{"webui":"/spaces/OPS/pages/12345"},"metadata":{"labels":{"results":[{"name":"oncall"}]}},"ancestors":[{"id":"1","title":"Ops home"}],"body":{"storage":{"value":"<p>Hello &amp; bye. Token ghp_abcdefghijklmnopqrstuvwxyz0123456789</p>"}}}"#
    nonisolated static let search = #"{"issues":[{"key":"KAN-1","fields":{"summary":"Token ghp_abcdefghijklmnopqrstuvwxyz0123456789 leaked","status":{"name":"To Do"},"priority":{"name":"High"},"updated":"2026-11-01T10:00:00.000+0000"}}]}"#

    nonisolated static let cases: [Case] = [
        Case(fetcher: "confluence.search", input: ["query": "c++ \"deploy\"", "space": "ENG"],
             routes: ["/wiki/rest/api/search": #"{"results":[{"content":{"id":"9","title":"Deploys"},"resultGlobalContainer":{"title":"Eng"},"excerpt":"how to","url":"/spaces/ENG/pages/9"}]}"#],
             path: "/wiki/rest/api/search") { $0["items"]?[0]?["id"] == "9" && $0["items"]?[0]?["url"]?.string?.hasSuffix("/wiki/spaces/ENG/pages/9") == true },
        Case(fetcher: "confluence.page", input: ["id": "12345"], routes: ["/wiki/rest/api/content/12345": page],
             path: "/wiki/rest/api/content/12345") {
            $0["title"] == "Runbook" && $0["space"]?["name"] == "Ops" && $0["version"] == 7 && $0["labels"] == ["oncall"]
                && $0["ancestors"]?[0]?["title"] == "Ops home" && $0["markdown"]?.string?.hasPrefix("Hello & bye.") == true
        },
        Case(fetcher: "confluence.children", input: ["id": "1"],
             routes: ["/wiki/rest/api/content/1/child/page": #"{"results":[{"id":"2","title":"Restart","_links":{"webui":"/spaces/OPS/pages/2"}}]}"#],
             path: "/wiki/rest/api/content/1/child/page") { $0["children"]?[0]?["title"] == "Restart" && $0["page_id"] == "1" },
        Case(fetcher: "confluence.attachments", input: ["id": "1"],
             routes: ["/wiki/rest/api/content/1/child/attachment": #"{"results":[{"title":"graph.png","metadata":{"mediaType":"image/png"},"extensions":{"fileSize":2048},"_links":{"download":"/download/attachments/1/graph.png"}}]}"#],
             path: "/wiki/rest/api/content/1/child/attachment") { $0["attachments"]?[0]?["media_type"] == "image/png" && $0["attachments"]?[0]?["size"] == 2048 },
        Case(fetcher: "confluence.spaces", input: [:], routes: ["/wiki/rest/api/space": #"{"results":[{"key":"OPS","name":"Operations","type":"global"}]}"#],
             path: "/wiki/rest/api/space") { $0["spaces"]?[0]?["key"] == "OPS" },
        Case(fetcher: "jira.my_issues", input: [:], routes: ["/rest/api/3/search/jql": search],
             path: "/rest/api/3/search/jql") { $0["items"]?[0]?["key"] == "KAN-1" && $0["items"]?[0]?["status"] == "To Do" },
        Case(fetcher: "jira.search", input: ["jql": "project = KAN"], routes: ["/rest/api/3/search/jql": search],
             path: "/rest/api/3/search/jql") { $0["items"]?[0]?["key"] == "KAN-1" && $0["items"]?[0]?["priority"] == "High" },
        Case(fetcher: "jira.issue", input: ["key": "kan-12"], routes: ["/rest/api/3/issue/KAN-12": issue], path: "/rest/api/3/issue/KAN-12") {
            $0["summary"] == "Fix login" && $0["description"]?.string?.contains("- iOS\n- **web**") == true
                && $0["links"]?[0]?["relation"] == "is blocked by" && $0["subtasks"]?[0]?["key"] == "KAN-13" && $0["latest_comments"]?[0]?["text"] == "On it"
        },
        Case(fetcher: "jira.comments", input: ["key": "KAN-12"],
             routes: ["/rest/api/3/issue/KAN-12/comment": #"{"total":1,"comments":[{"author":{"displayName":"Ada"},"created":"2026-11-10","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Done"}]}]}}]}"#],
             path: "/rest/api/3/issue/KAN-12/comment") { $0["comments"]?[0]?["text"] == "Done" && $0["total"] == 1 },
        Case(fetcher: "jira.changelog", input: ["key": "KAN-12"],
             routes: ["/rest/api/3/issue/KAN-12/changelog": #"{"values":[{"author":{"displayName":"Ada"},"created":"2026-11-10","items":[{"field":"status","fromString":"To Do","toString":"Done"}]}]}"#],
             path: "/rest/api/3/issue/KAN-12/changelog") { $0["changes"]?[0]?["items"]?[0]?["to"] == "Done" },
        Case(fetcher: "jira.projects", input: [:],
             routes: ["/rest/api/3/project/search": #"{"values":[{"key":"KAN","name":"Kanban","projectTypeKey":"software","lead":{"displayName":"Ada"}}]}"#],
             path: "/rest/api/3/project/search") { $0["projects"]?[0]?["lead"] == "Ada" },
    ]

    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    let site = "acme-\(UUID().uuidString.prefix(8).lowercased()).atlassian.net"
    let sandbox = Sandbox()
    let atlassian: AtlassianIntegration
    let mirror = MemorySyncedStore()
    let clock = Clock()

    init() {
        sandbox.configure(site: "https://" + site)
        atlassian = sandbox.integration()
        atlassian.mirror = mirror
        let clock = clock
        atlassian.now = { clock.now }
    }

    func serve(_ routes: [String: String], status: Int = 200) {
        StubURLProtocol.serve(site) { request in
            routes[request.url?.path() ?? ""].map { .init(status: status, body: Data($0.utf8)) } ?? .init(status: 404, body: Data("{}".utf8))
        }
    }

    func fetch(_ name: String, _ input: JSONValue = [:]) async throws -> JSONValue {
        try await #require(atlassian.fetchers.first { $0.name == name }).fetch(input)
    }

    func run(_ name: String, _ input: JSONValue = [:]) async throws -> JSONValue {
        try await #require(atlassian.tools.first { $0.name == name }).run(input)
    }

    // MARK: Fetchers and readers

    @Test(arguments: cases)
    func fetcherStoresAndReaderReads(_ c: Case) async throws {
        defer { sandbox.cleanUp() }
        serve(c.routes)
        let resource = try #require(atlassian.resources.first { $0.fetcher == c.fetcher })

        let before = try await run(resource.reader, c.input)
        #expect(before["fetched"] == false && before["rows"] == [] && before["refresh"]?["fetcher"] == .string(c.fetcher))

        let receipt = try await fetch(c.fetcher, c.input)
        #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0 && receipt["synced_at"]?.string != nil)
        #expect(receipt["keys"]?.array?.count == 1 && receipt["keys"]?[0]?.string?.hasPrefix(resource.kind + "/") == true)
        #expect(receipt["read_with"]?.string?.hasPrefix(resource.reader + " {") == true)
        let sent = StubURLProtocol.requests(site)
        #expect(sent.contains { $0.request.url?.path() == c.path })
        #expect(sent.allSatisfy { $0.request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Basic ") == true })

        let answer = try await run(resource.reader, c.input)
        #expect(c.check(answer), "\(answer.jsonString())")
        #expect(answer["stale"] == false && answer["synced_at"]?.string != nil && answer["refresh"]?["fetcher"] == .string(c.fetcher))

        clock.now += 60
        #expect(try await fetch(c.fetcher, c.input)["unchanged"] == 1)
        // Secrets never reach the mirror (or Dashii).
        let stored = mirror.records(kind: resource.kind, scope: site)
        #expect(stored.count == 1 && stored.allSatisfy { $0.source == "atlassian" })
        #expect(stored.allSatisfy { !$0.value.jsonString().contains("hunter2secret") && !$0.value.jsonString().contains("ghp_abcdefghij") })
        #expect(!answer.jsonString().contains("hunter2secret") && !answer.jsonString().contains("ghp_abcdefghij"))
    }

    @Test func requestsMatchTheOldTools() async throws {
        defer { sandbox.cleanUp() }
        serve(["/wiki/rest/api/search": #"{"results":[]}"#, "/rest/api/3/search/jql": #"{"issues":[]}"#, "/wiki/rest/api/content/12345": Self.page])
        _ = try await fetch("confluence.page", ["id": "12345"])
        let pageURL = try #require(StubURLProtocol.requests(site).first?.request.url)
        #expect(URLComponents(url: pageURL, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "expand", value: "body.storage,version,space,ancestors,metadata.labels")])
        #expect(try await run("confluence_get_page", ["id": "12345"])["url"] == .string("https://\(site)/wiki/spaces/OPS/pages/12345"))
        _ = try await fetch("confluence.search", ["query": "c++ \"deploy\"", "space": "ENG"])
        let url = try #require(StubURLProtocol.requests(site).last?.request.url)
        #expect(url.query()?.contains("c%2B%2B") == true)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "cql" }?.value == #"siteSearch ~ "c++ \"deploy\"" AND type = page AND space = "ENG""#)
        #expect(items.first { $0.name == "limit" }?.value == "15")

        _ = try await fetch("jira.my_issues")
        let mine = try #require(StubURLProtocol.requests(site).last)
        #expect(mine.request.httpMethod == "POST" && mine.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try JSONValue.parse(try #require(mine.body)) == [
            "jql": "assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC", "fields": ["summary", "status", "priority", "updated"], "maxResults": 50,
        ])
        _ = try await fetch("jira.search", ["jql": "project = KAN"])
        let body = try JSONValue.parse(try #require(StubURLProtocol.requests(site).last?.body))
        #expect(body["jql"] == "project = KAN" && body["maxResults"] == 25)
    }

    @Test func readersFlagStaleDataAndOfflineKeepsTheCopy() async throws {
        defer { sandbox.cleanUp() }
        serve(["/rest/api/3/issue/KAN-12": Self.issue])
        _ = try await fetch("jira.issue", ["key": "KAN-12"])
        clock.now += 16 * 60
        let stale = try await run("jira_issue", ["key": "KAN-12"])
        #expect(stale["stale"] == true && stale["summary"] == "Fix login")
        #expect(stale["refresh"] == ["fetcher": "jira.issue", "input": ["key": "KAN-12"]])
        // Offline: the fetch says so; the stored copy is still read.
        serve(["/rest/api/3/issue/KAN-12": "{}"], status: 503)
        await #expect(throws: (any Error).self) { _ = try await fetch("jira.issue", ["key": "KAN-12"]) }
        #expect(try await run("jira_issue", ["key": "KAN-12"])["summary"] == "Fix login")
    }

    @Test func recordsFromEarlierVersionsStayReadable() async throws {
        defer { sandbox.cleanUp() }
        // 1.6 kept a page read by Dashii under its id; 1.7 reads the same record.
        mirror.upsert([SyncedRecord(kind: "confluence.page", scope: site, key: "77", value: ["id": "77", "title": "Old"], source: "atlassian", updatedAt: clock.now)])
        let page = try await run("confluence_get_page", ["id": "77"])
        #expect(page["title"] == "Old" && page["stale"] == false)
    }

    @Test func inputsAreChecked() async throws {
        defer { sandbox.cleanUp() }
        await #expect(throws: ToolError("Issue key should look like KAN-1234.")) { _ = try await run("jira_issue", ["key": "not a key"]) }
        await #expect(throws: ToolError("Page id should be letters and digits, like 123456.")) { _ = try await fetch("confluence.page", ["id": "../../x"]) }
        await #expect(throws: ToolError("Give jql.")) { _ = try await run("jira_jql_search", ["jql": "  "]) }
        // Same issue, however it's written: one record.
        serve(["/rest/api/3/issue/KAN-12": Self.issue])
        _ = try await fetch("jira.issue", ["key": " kan-12 "])
        #expect(try await run("jira_issue", ["key": "KAN-12", "fresh": true])["summary"] == "Fix login")
    }

    @Test func searchesRememberHitsAndExpireAfterADay() async throws {
        defer { sandbox.cleanUp() }
        serve(["/rest/api/3/search/jql": Self.search])
        _ = try await fetch("jira.search", ["jql": "project = KAN"])
        #expect(mirror.records(kind: "jira.hit", scope: site).map(\.key) == ["KAN-1"])
        let cached = try await run("atlassian_cached", ["text": "leaked"])
        #expect(cached[0]?["key"] == "KAN-1" && cached[0]?["kind"] == "jira.hit")
        #expect(try await run("atlassian_cached", ["text": "nothing like it"]) == [])

        clock.now += 2 * 86_400
        _ = try await fetch("jira.search", ["jql": "project = WEB"])
        #expect(mirror.records(kind: "jira.search", scope: site).map { $0.value["input"]?["jql"] } == ["project = WEB"])

        #expect(atlassian.cachedCount("jira.search") == 1 && atlassian.cachedCount("jira.hit") == 1)
        atlassian.clearCache()
        #expect(atlassian.cachedCount("jira.search") == 0 && atlassian.cachedCount("jira.hit") == 0)
    }

    @Test func fetchersNeedTheSite() async throws {
        let bare = Sandbox()
        defer { bare.cleanUp(); sandbox.cleanUp() }
        let atlassian = bare.integration()
        atlassian.mirror = MemorySyncedStore()
        await #expect(throws: ToolError("Set your Atlassian site (https://your-team.atlassian.net) in Settings › Atlassian.")) {
            _ = try await #require(atlassian.fetchers.first { $0.name == "jira.my_issues" }).fetch([:])
        }
        // Readers don't.
        #expect(try await #require(atlassian.tools.first { $0.name == "jira_myself_issues" }).run([:])["fetched"] == false)
    }

    @Test func storageBecomesMarkdown() {
        defer { sandbox.cleanUp() }
        let html = """
            <h2>Restart</h2><p>Run <code>make up</code> then <strong>check</strong> <a href="https://x.dev/logs">logs</a>.</p>\
            <ol><li><p>First</p></li><li>Second<ul><li>nested</li></ul></li></ol>\
            <table><tbody><tr><th>Env</th><th>URL</th></tr><tr><td>qa</td><td>q.dev</td></tr></tbody></table>\
            <ac:structured-macro ac:name="code"><ac:parameter ac:name="language">bash</ac:parameter><ac:plain-text-body><![CDATA[kubectl get pods <x>]]></ac:plain-text-body></ac:structured-macro>\
            <ac:structured-macro ac:name="warning"><ac:rich-text-body><p>Prod only</p></ac:rich-text-body></ac:structured-macro>\
            <p>See <ac:link><ri:page ri:content-title="Deploys" /></ac:link> &amp; more.</p>
            """
        let markdown = AtlassianFormats.markdown(fromStorage: html)
        #expect(markdown.contains("## Restart"))
        #expect(markdown.contains("Run `make up` then **check** [logs](https://x.dev/logs)."))
        #expect(markdown.contains("1. First\n1. Second\n  - nested"))
        #expect(markdown.contains("| Env | URL |\n| --- | --- |\n| qa | q.dev |"))
        #expect(markdown.contains("```bash\nkubectl get pods <x>\n```"))
        #expect(markdown.contains("> **Warning:** Prod only"))
        #expect(markdown.contains("See [[Deploys]] & more."))
    }

    @Test func fetchedDataIsQueryable() async throws {
        defer { sandbox.cleanUp() }
        serve(["/rest/api/3/issue/KAN-12": Self.issue])
        _ = try await fetch("jira.issue", ["key": "KAN-12"])
        mirror.upsert([SyncedRecord(kind: "jira.hit", scope: site, key: "KAN-99", value: ["key": "KAN-99", "summary": "Other", "status": "To Do"],
                                    source: "atlassian", updatedAt: clock.now.addingTimeInterval(-3600))])

        let engine = QueryEngine(datasets: atlassian.datasets)
        let rows = try await engine.run("from jira_cache | sort key | select key, full, priority, stale").rows
        #expect(rows == [["key": "KAN-12", "full": true, "priority": "High", "stale": false], ["key": "KAN-99", "full": false, "priority": .null, "stale": true]])
        #expect(try await engine.run("from confluence").rows.isEmpty)
    }

    // MARK: No network for Dashii and agents

    @Test func noToolDashiiGetsCallsTheSite() async throws {
        defer { sandbox.cleanUp() }
        let values: [String: JSONValue] = ["id": "12345", "key": "KAN-12", "query": "deploy", "jql": "project = KAN"]
        #expect(await NetworkSentinel.requests(running: atlassian.tools, values: values) == [])
        // With data stored, the readers still only read.
        serve(Self.cases.reduce(into: [:]) { routes, c in routes.merge(c.routes) { first, _ in first } })
        for c in Self.cases { _ = try await fetch(c.fetcher, c.input) }
        #expect(await NetworkSentinel.requests(running: atlassian.tools, values: values) == [])
    }

    @Test func toolsFetchersAndVerbsLineUp() {
        defer { sandbox.cleanUp() }
        let readers = atlassian.tools.filter(\.isForDashii).map(\.name)
        #expect(readers == atlassian.tools.map(\.name) && atlassian.tools.allSatisfy { !$0.requiresApproval && !$0.writesRemotely })
        #expect(atlassian.fetchers.map(\.name) == atlassian.resources.map(\.fetcher) + ["confluence.pages"])
        #expect(atlassian.resources.allSatisfy { AtlassianIntegration.cacheKinds.map(\.kind).contains($0.kind) })
        // The DashQL verbs still name tools Dashii gets.
        #expect(atlassian.verbs.allSatisfy { readers.contains($0.tool) })
    }
}
