import DashKit
import Foundation
import Testing

/// What Claude reads from Jira and Confluence is mirrored, reused while fresh, and served stale offline.
@MainActor
@Suite(.serialized)
struct AtlassianCacheTests {
    nonisolated private static let issue = #"{"key":"LAF-12","fields":{"summary":"Fix login","status":{"name":"In Progress"},"issuetype":{"name":"Bug"},"priority":{"name":"High"},"assignee":{"displayName":"Ada"},"reporter":{"displayName":"Bob"},"updated":"2026-11-10T10:00:00.000+0000","labels":["auth"],"description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Users can't sign in. Set "},{"type":"text","text":"DB_PASSWORD=hunter2secret","marks":[{"type":"code"}]}]},{"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"iOS"}]}]},{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"web","marks":[{"type":"strong"}]}]}]}]}]},"subtasks":[{"key":"LAF-13","fields":{"summary":"Test","status":{"name":"To Do"}}}],"issuelinks":[{"type":{"inward":"is blocked by","outward":"blocks"},"inwardIssue":{"key":"CAP-1","fields":{"summary":"Gateway","status":{"name":"Done"}}}}],"comment":{"total":1,"comments":[{"author":{"displayName":"Ada"},"created":"2026-11-10","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"On it"}]}]}}]}}}"#

    private func setUp() -> (Sandbox, AtlassianIntegration, MemorySyncedStore, Clock) {
        let sandbox = Sandbox()
        sandbox.configure()
        let atlassian = sandbox.integration()
        let mirror = MemorySyncedStore()
        atlassian.mirror = mirror
        let clock = Clock()
        atlassian.now = { clock.now }
        return (sandbox, atlassian, mirror, clock)
    }

    final class Clock { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private func run(_ atlassian: AtlassianIntegration, _ name: String, _ input: JSONValue) async throws -> JSONValue {
        try await #require(atlassian.tools.first { $0.name == name }).run(input)
    }

    @Test func issueIsReusedUntilItExpiresAndFreshGoesOnline() async throws {
        let (sandbox, atlassian, mirror, clock) = setUp()
        defer { sandbox.cleanUp() }
        StubURLProtocol.reset { _ in .init(body: Data(Self.issue.utf8)) }

        let first = try await run(atlassian, "jira_issue", ["key": "laf-12"])
        #expect(first["from_cache"] == false && first["summary"] == "Fix login" && first["status"] == "In Progress")
        #expect(first["description"]?.string?.contains("- iOS\n- **web**") == true)
        #expect(first["links"]?[0]?["relation"] == "is blocked by" && first["subtasks"]?[0]?["key"] == "LAF-13")
        #expect(first["latest_comments"]?[0]?["text"] == "On it")
        // Secrets never reach the mirror (or Claude).
        let stored = try #require(mirror.record(kind: "jira.issue", scope: "acme.atlassian.net", key: "LAF-12"))
        #expect(!stored.value.jsonString().contains("hunter2secret") && !first.jsonString().contains("hunter2secret"))
        #expect(StubURLProtocol.requests.count == 1)

        clock.now += 60
        let second = try await run(atlassian, "jira_issue", ["key": "LAF-12"])
        #expect(second["from_cache"] == true && StubURLProtocol.requests.count == 1)

        _ = try await run(atlassian, "jira_issue", ["key": "LAF-12", "fresh": true])
        #expect(StubURLProtocol.requests.count == 2)

        clock.now += 16 * 60
        let expired = try await run(atlassian, "jira_issue", ["key": "LAF-12"])
        #expect(expired["from_cache"] == false && StubURLProtocol.requests.count == 3)
        await #expect(throws: ToolError.self) { try await run(atlassian, "jira_issue", ["key": "not a key"]) }
    }

    @Test func offlineServesTheStaleCopy() async throws {
        let (sandbox, atlassian, _, clock) = setUp()
        defer { sandbox.cleanUp() }
        StubURLProtocol.reset { _ in .init(body: Data(Self.issue.utf8)) }
        _ = try await run(atlassian, "jira_issue", ["key": "LAF-12"])
        StubURLProtocol.reset { _ in .init(status: 503, body: Data("{}".utf8)) }
        clock.now += 3600
        let stale = try await run(atlassian, "jira_issue", ["key": "LAF-12"])
        #expect(stale["stale"] == true && stale["from_cache"] == true && stale["summary"] == "Fix login")
        #expect(stale["error"]?.string?.contains("503") == true)
        // Never cached: the error comes through.
        await #expect(throws: (any Error).self) { try await run(atlassian, "jira_issue", ["key": "LAF-99"]) }
    }

    @Test func searchesGoOnlineAndRememberHits() async throws {
        let (sandbox, atlassian, mirror, _) = setUp()
        defer { sandbox.cleanUp() }
        StubURLProtocol.reset { _ in .init(body: Data(#"{"issues":[{"key":"LAF-1","fields":{"summary":"Token ghp_abcdefghijklmnopqrstuvwxyz0123456789 leaked","status":{"name":"To Do"}}}]}"#.utf8)) }
        let hits = try await run(atlassian, "jira_jql_search", ["jql": "project = LAF"])
        #expect(hits[0]?["key"] == "LAF-1" && hits.jsonString().contains("ghp_abcdefghij") == false)
        _ = try await run(atlassian, "jira_jql_search", ["jql": "project = LAF"])
        #expect(StubURLProtocol.requests.count == 2)
        #expect(mirror.records(kind: "jira.hit", scope: "acme.atlassian.net").map(\.key) == ["LAF-1"])
        let body = try JSONValue.parse(try #require(StubURLProtocol.requests.first?.body))
        #expect(body["jql"] == "project = LAF" && body["maxResults"] == 25)

        let cached = try await run(atlassian, "atlassian_cached", ["text": "leaked"])
        #expect(cached[0]?["key"] == "LAF-1" && cached[0]?["kind"] == "jira.hit")
        #expect(try await run(atlassian, "atlassian_cached", ["text": "nothing like it"]) == [])

        #expect(atlassian.cachedCount("jira.hit") == 1)
        atlassian.clearCache()
        #expect(atlassian.cachedCount("jira.hit") == 0)
    }

    @Test func confluenceListsAreCached() async throws {
        let (sandbox, atlassian, _, _) = setUp()
        defer { sandbox.cleanUp() }
        StubURLProtocol.reset { request in
            let path = request.url?.path() ?? ""
            if path.hasSuffix("/child/page") { return .init(body: Data(#"{"results":[{"id":"2","title":"Restart","_links":{"webui":"/spaces/OPS/pages/2"}}]}"#.utf8)) }
            if path.hasSuffix("/child/attachment") { return .init(body: Data(#"{"results":[{"title":"graph.png","metadata":{"mediaType":"image/png"},"extensions":{"fileSize":2048},"_links":{"download":"/download/attachments/1/graph.png"}}]}"#.utf8)) }
            return .init(body: Data(#"{"results":[{"key":"OPS","name":"Operations","type":"global"}]}"#.utf8))
        }
        let children = try await run(atlassian, "confluence_page_children", ["id": "1"])
        #expect(children["children"]?[0]?["title"] == "Restart" && children["children"]?[0]?["url"] == "https://acme.atlassian.net/wiki/spaces/OPS/pages/2")
        let attachments = try await run(atlassian, "confluence_page_attachments", ["id": "1"])
        #expect(attachments["attachments"]?[0]?["media_type"] == "image/png" && attachments["attachments"]?[0]?["size"] == 2048)
        let spaces = try await run(atlassian, "confluence_spaces", [:])
        #expect(spaces["spaces"]?[0]?["key"] == "OPS")
        _ = try await run(atlassian, "confluence_spaces", [:])
        #expect(StubURLProtocol.requests.count == 3)
    }

    @Test func storageBecomesMarkdown() {
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
}
