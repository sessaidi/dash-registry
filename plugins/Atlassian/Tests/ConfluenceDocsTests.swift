import DashKit
import Foundation
import Testing

/// Confluence pages fetched into Dash's database on request, then given to the knowledge graph.
@MainActor
@Suite(.serialized)
struct ConfluenceDocsTests {
    nonisolated static let search = #"{"results":[{"content":{"id":"101","title":"Billing runbook","version":{"number":3}}}]}"#
    nonisolated static let page = #"{"id":"101","title":"Billing runbook","version":{"number":3,"when":"2026-11-10T10:00:00.000Z"},"space":{"key":"ENG","name":"Engineering"},"metadata":{"labels":{"results":[{"name":"runbook"}]}},"_links":{"webui":"/spaces/ENG/pages/101"},"body":{"storage":{"value":"<h1>Restart</h1><p>See KAN-12. Set DB_PASSWORD=hunter2secret</p>"}}}"#

    private func setUp() -> (Sandbox, AtlassianIntegration, MemorySyncedStore) {
        let sandbox = Sandbox()
        sandbox.configure()
        let atlassian = sandbox.integration()
        let mirror = MemorySyncedStore()
        atlassian.mirror = mirror
        StubURLProtocol.reset { request in
            .init(body: Data((request.url?.path.hasSuffix("/search") == true ? Self.search : Self.page).utf8))
        }
        return (sandbox, atlassian, mirror)
    }

    @Test func pagesAreStoredOnceThenGivenToTheKnowledgeGraph() async throws {
        let (sandbox, atlassian, mirror) = setUp()
        defer { sandbox.cleanUp() }
        let fetcher = try #require(atlassian.fetchers.first { $0.name == "confluence.pages" })
        let receipt = try await fetcher.fetch(["query": "billing-api", "repo": "acme/billing-api"])
        #expect(receipt["stored"] == 1 && receipt["pages"]?[0]?["title"] == "Billing runbook")
        let stored = try #require(mirror.record(kind: "confluence.doc", scope: "acme.atlassian.net", key: "101"))
        #expect(stored.value["markdown"]?.string?.contains("Restart") == true)
        #expect(!stored.value.jsonString().contains("hunter2secret"))
        // The same version again: only the search runs, and the new words are remembered.
        let requests = StubURLProtocol.requests.count
        let again = try await fetcher.fetch(["query": "invoices"])
        #expect(again["unchanged"] == 1 && StubURLProtocol.requests.count == requests + 1)
        #expect(mirror.record(kind: "confluence.doc", scope: "acme.atlassian.net", key: "101")?.value["terms"] == ["billing-api", "invoices"])

        let entity = try #require(atlassian.knowledge.first)
        #expect(entity.id == "doc:confluence:101" && entity.kind == "doc" && entity.title == "Billing runbook")
        #expect(entity.links == [KnowledgeLink(to: "repo:acme/billing-api", kind: "documents")])
        #expect(entity.url?.absoluteString == "https://acme.atlassian.net/wiki/spaces/ENG/pages/101" && entity.updated != nil)
        #expect(atlassian.datasets.contains { $0.name == "confluence_docs" })
    }

    @Test func emptyWordsAreRefused() async throws {
        let (sandbox, atlassian, _) = setUp()
        defer { sandbox.cleanUp() }
        await #expect(throws: ToolError.self) { _ = try await atlassian.fetchPages(query: " ", repo: nil, space: nil, limit: 5) }
    }
}
