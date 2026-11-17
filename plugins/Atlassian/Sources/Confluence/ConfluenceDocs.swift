import DashKit
import Foundation

/// Confluence pages kept in Dash's database for Dashii and the knowledge graph. The integration
/// fetches them on request (`confluence.pages`): Dash asks for the pages that mention each of the
/// user's repositories, Dashii asks for more when a question needs them. Stored pages become
/// `doc` entities in the knowledge graph, linked to the repositories they're about.
extension AtlassianIntegration {
    /// Mirror kind of a stored page (`AtlassianIntegration.cacheKinds` lists it for Settings).
    static let docKind = "confluence.doc"
    /// Text kept per page: enough for search and for Dashii to read it whole.
    static let docLimit = 60_000

    var docsFetcher: DataFetcher {
        DataFetcher(
            name: "confluence.pages",
            summary: "Confluence pages that mention some words (a repository, service, feature or ticket), stored in Dash's database and the knowledge graph as docs. Read them with knowledge search (kind doc) or `from confluence_docs`.",
            properties: ["query": JSONSchema.string("Words the pages should mention, e.g. a repository or service name."),
                         "repo": JSONSchema.string("Optional owner/name of the repository the pages are about: links them to it in the knowledge graph."),
                         "space": JSONSchema.string("Optional space key to search in."),
                         "limit": JSONSchema.integer("How many pages at most (default 20, at most 50).")],
            required: ["query"]
        ) { [weak self] input in
            guard let self else { throw ToolError("Atlassian isn't ready.") }
            return try await fetchPages(query: input["query"]?.string ?? "", repo: input["repo"]?.string,
                                        space: input["space"]?.string, limit: input["limit"]?.int ?? 20)
        }
    }

    /// Searches pages mentioning `query` and stores each one (its body fetched only when it
    /// changed). Returns the receipt, with the pages' ids, titles and links.
    func fetchPages(query: String, repo: String?, space: String?, limit: Int) async throws -> JSONValue {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { throw ToolError("Say what the pages should mention.") }
        var cql = "siteSearch ~ \"\(words.replacingOccurrences(of: "\"", with: "\\\""))\" AND type = page"
        if let space, !space.isEmpty { cql += " AND space = \"\(space.replacingOccurrences(of: "\"", with: ""))\"" }
        cql += " ORDER BY lastmodified DESC"
        let found = try await get("/wiki/rest/api/search",
                                  query: [URLQueryItem(name: "cql", value: cql), URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50))),
                                          // The version: a page's body is fetched again only when it changed.
                                          URLQueryItem(name: "expand", value: "content.version")],
                                  service: "Confluence")
        var stored = 0, unchanged = 0
        var pages: [JSONValue] = []
        var keys: [String] = []
        for hit in found["results"]?.array ?? [] {
            guard let id = hit["content"]?["id"]?.string, Self.validPageID(id) else { continue }
            let version = hit["content"]?["version"]?["number"]?.int
            let existing = mirror?.record(kind: Self.docKind, scope: cacheScope, key: id)?.value
            var record: JSONValue
            if let existing, version == nil || existing["version"]?.int == version {
                record = existing
                unchanged += 1
            } else {
                let page = try await get("/wiki/rest/api/content/\(id)",
                                         query: [URLQueryItem(name: "expand", value: "body.storage,version,space,metadata.labels")],
                                         service: "Confluence")
                record = Self.docRecord(page, site: siteURL?.absoluteString ?? "")
                stored += 1
            }
            record = Self.adding(term: words, repo: repo, to: record, previous: existing)
            remember(Self.docKind, key: id, value: record)
            pages.append(["id": .string(id), "title": record["title"] ?? .null, "url": record["url"] ?? .null])
            keys.append(Self.docKind + "/" + id)
        }
        return Self.receipt(stored: stored, unchanged: unchanged, keys: keys, syncedAt: now(),
                            readWith: "knowledge search (kind doc), or `from confluence_docs` in DashQL")
            .merging(["pages": .array(pages)])
    }

    /// A page as stored: its text as Markdown, cut at `docLimit`.
    static func docRecord(_ page: JSONValue, site: String) -> JSONValue {
        let markdown = AtlassianFormats.markdown(fromStorage: page["body"]?["storage"]?["value"]?.string ?? "")
        return ["id": page["id"] ?? .null, "title": page["title"] ?? .null,
                "space": page["space"]?["key"] ?? .null, "space_name": page["space"]?["name"] ?? .null,
                "version": page["version"]?["number"] ?? .null, "updated": page["version"]?["when"] ?? .null,
                "url": .string(site + "/wiki" + (page["_links"]?["webui"]?.string ?? "")),
                "labels": .array((page["metadata"]?["labels"]?["results"]?.array ?? []).compactMap { $0["name"] }),
                "markdown": .string(String(markdown.prefix(docLimit)))]
    }

    /// Remembers which words found the page and which repositories it's about, keeping earlier ones.
    static func adding(term: String, repo: String?, to record: JSONValue, previous: JSONValue?) -> JSONValue {
        func merged(_ key: String, _ value: String?) -> JSONValue {
            var values = (previous?[key]?.array ?? record[key]?.array ?? []).compactMap(\.string)
            if let value, !value.isEmpty, !values.contains(value) { values.append(value) }
            return .array(values.map(JSONValue.string))
        }
        return record.merging(["terms": merged("terms", term), "repos": merged("repos", repo)])
    }

    /// Stored pages, newest first.
    var docs: [JSONValue] {
        (mirror?.records(kind: Self.docKind, scope: cacheScope) ?? [])
            .map(\.value)
            .sorted { ($0["updated"]?.string ?? "") > ($1["updated"]?.string ?? "") }
    }

    /// Stored pages for the knowledge graph: `doc` entities linked to their repositories (ticket
    /// keys in the text are linked by Dash).
    var knowledge: [KnowledgeEntity] {
        docs.compactMap { doc in
            guard let id = doc["id"]?.string, let title = doc["title"]?.string else { return nil }
            let repos = (doc["repos"]?.array ?? []).compactMap(\.string)
            return KnowledgeEntity(
                id: "doc:confluence:\(id)", kind: "doc", title: title, text: doc["markdown"]?.string ?? "",
                url: doc["url"]?.string.flatMap(URL.init(string:)),
                updated: doc["updated"]?.string.flatMap { ISO8601DateFormatter.withFractions.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) },
                links: repos.map { KnowledgeLink(to: "repo:\($0)", kind: "documents") })
        }
    }
}

extension ISO8601DateFormatter {
    /// Confluence's "2026-11-15T10:02:03.123Z".
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
