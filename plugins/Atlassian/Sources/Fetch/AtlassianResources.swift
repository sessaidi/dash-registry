import DashKit
import Foundation

/// Something Dash can fetch from Jira or Confluence and read back: the fetcher calls the site and
/// stores the compact answer; the reader (same input) returns it with its freshness, or says to
/// fetch first.
struct AtlassianResource {
    /// The fetcher's name, also the mirror kind: "confluence.page", "jira.issue".
    let fetcher: String
    /// The Dashii tool that reads it (the old live tool's name).
    let reader: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let properties: [String: JSONValue]
    var required: [String] = []
    /// The record's key for one thing (a page id, an issue key, "all"). Nil for answers to a query
    /// (searches): those are keyed by the input's hash, keep the input, and are kept a day.
    let key: (@Sendable (JSONValue) -> String)?
    /// Calls the site and returns the compact answer that gets stored.
    let load: @MainActor (AtlassianIntegration, JSONValue) async throws -> JSONValue

    var kind: String { fetcher }
}

extension AtlassianIntegration {
    /// Everything the Atlassian tools used to read online, now fetched into Dash and read there.
    var resources: [AtlassianResource] {
        let pageID = JSONSchema.string("Page id.")
        let issueKey = JSONSchema.string("Issue key, e.g. KAN-1234.")
        let byID: @Sendable (JSONValue) -> String = { $0["id"]?.string ?? "" }
        let byKey: @Sendable (JSONValue) -> String = { $0["key"]?.string ?? "" }
        let all: @Sendable (JSONValue) -> String = { _ in "all" }
        return [
            // MARK: Confluence
            AtlassianResource(
                fetcher: "confluence.search", reader: "confluence_search",
                summary: "Confluence pages matching some words (CQL siteSearch): id, title, space, excerpt and link. For docs, runbooks, designs or decisions that might be written down.",
                properties: ["query": JSONSchema.string("Words to search for."), "space": JSONSchema.string("Optional space key to search in."),
                             "limit": JSONSchema.integer("How many (default 15, at most 50).")],
                required: ["query"], key: nil
            ) { atlassian, input in
                var cql = "siteSearch ~ \"\((input["query"]?.string ?? "").replacingOccurrences(of: "\"", with: "\\\""))\" AND type = page"
                if let space = input["space"]?.string { cql += " AND space = \"\(space.replacingOccurrences(of: "\"", with: ""))\"" }
                let result = try await atlassian.get(
                    "/wiki/rest/api/search",
                    query: [URLQueryItem(name: "cql", value: cql), URLQueryItem(name: "limit", value: String(Self.limit(input, 15, 50)))],
                    service: "Confluence")
                let hits: [JSONValue] = (result["results"]?.array ?? []).map { item in
                    ["id": item["content"]?["id"] ?? .null, "title": item["content"]?["title"] ?? item["title"] ?? .null,
                     "space": item["resultGlobalContainer"]?["title"] ?? .null, "excerpt": item["excerpt"] ?? .null,
                     "url": .string(atlassian.siteBase + "/wiki" + (item["url"]?.string ?? ""))]
                }
                for hit in hits { if let id = hit["id"]?.string { atlassian.remember("confluence.hit", key: id, value: hit) } }
                return .array(hits)
            },
            AtlassianResource(
                fetcher: "confluence.page", reader: "confluence_get_page",
                summary: "A Confluence page by id (from confluence_search): title, space, version, last update, labels, ancestors (breadcrumb) and the body as Markdown (cut at 60,000 characters).",
                properties: ["id": pageID], required: ["id"], key: byID
            ) { atlassian, input in
                let id = input["id"]?.string ?? ""
                let page = try await atlassian.get("/wiki/rest/api/content/\(id)",
                                                   query: [URLQueryItem(name: "expand", value: "body.storage,version,space,ancestors,metadata.labels")],
                                                   service: "Confluence")
                return Self.pageRecord(page, site: atlassian.siteBase)
            },
            AtlassianResource(
                fetcher: "confluence.children", reader: "confluence_page_children",
                summary: "The child pages of a Confluence page (id, title), e.g. to walk a runbook section.",
                properties: ["id": JSONSchema.string("Parent page id.")], required: ["id"], key: byID
            ) { atlassian, input in
                let id = input["id"]?.string ?? ""
                let result = try await atlassian.get("/wiki/rest/api/content/\(id)/child/page", query: [URLQueryItem(name: "limit", value: "100")], service: "Confluence")
                return ["page_id": .string(id), "children": .array((result["results"]?.array ?? []).map { child in
                    ["id": child["id"] ?? .null, "title": child["title"] ?? .null,
                     "url": .string(atlassian.siteBase + "/wiki" + (child["_links"]?["webui"]?.string ?? ""))]
                })]
            },
            AtlassianResource(
                fetcher: "confluence.attachments", reader: "confluence_page_attachments",
                summary: "Attachments of a Confluence page: file name, type, size, last update and download link (metadata only, files aren't downloaded).",
                properties: ["id": pageID], required: ["id"], key: byID
            ) { atlassian, input in
                let id = input["id"]?.string ?? ""
                let result = try await atlassian.get("/wiki/rest/api/content/\(id)/child/attachment",
                                                     query: [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "expand", value: "version")], service: "Confluence")
                return ["page_id": .string(id), "attachments": .array((result["results"]?.array ?? []).map { item in
                    ["title": item["title"] ?? .null, "media_type": item["metadata"]?["mediaType"] ?? item["extensions"]?["mediaType"] ?? .null,
                     "size": item["extensions"]?["fileSize"] ?? .null, "updated": item["version"]?["when"] ?? .null,
                     "download": .string(atlassian.siteBase + "/wiki" + (item["_links"]?["download"]?.string ?? ""))]
                })]
            },
            AtlassianResource(
                fetcher: "confluence.spaces", reader: "confluence_spaces",
                summary: "Confluence spaces (key, name, type), to know where to search.",
                properties: [:], key: all
            ) { atlassian, _ in
                let result = try await atlassian.get("/wiki/rest/api/space", query: [URLQueryItem(name: "limit", value: "250")], service: "Confluence")
                return ["spaces": .array((result["results"]?.array ?? []).map { space in
                    ["key": space["key"] ?? .null, "name": space["name"] ?? .null, "type": space["type"] ?? .null]
                })]
            },
            // MARK: Jira
            AtlassianResource(
                fetcher: "jira.my_issues", reader: "jira_myself_issues",
                summary: "The open Jira issues assigned to the signed-in user (not Done), most recently updated first, up to 50: key, summary, status and url.",
                properties: [:], key: all
            ) { atlassian, _ in
                let result = try await atlassian.post("/rest/api/3/search/jql", body: Self.myIssuesBody, service: "Jira")
                return .array((result["issues"]?.array ?? []).map { issue in
                    let hit = Self.hitRecord(issue, site: atlassian.siteBase)
                    atlassian.remember("jira.hit", key: hit["key"]?.string ?? "", value: hit)
                    return ["key": hit["key"] ?? .null, "summary": hit["summary"] ?? .null, "status": hit["status"] ?? .null, "url": hit["url"] ?? .null]
                })
            },
            AtlassianResource(
                fetcher: "jira.search", reader: "jira_jql_search",
                summary: "Jira issues matching a JQL query (read-only), e.g. project = KAN AND status = \"In Progress\" ORDER BY updated DESC: key, summary, status, type, priority, assignee, updated and url, up to 50.",
                properties: ["jql": JSONSchema.string("JQL query."), "limit": JSONSchema.integer("How many (default 25, at most 50).")],
                required: ["jql"], key: nil
            ) { atlassian, input in
                let result = try await atlassian.post("/rest/api/3/search/jql",
                                                      body: ["jql": input["jql"] ?? "", "fields": Self.hitFields, "maxResults": .number(Double(Self.limit(input, 25, 50)))],
                                                      service: "Jira")
                return .array((result["issues"]?.array ?? []).map { issue in
                    let hit = Self.hitRecord(issue, site: atlassian.siteBase)
                    atlassian.remember("jira.hit", key: hit["key"]?.string ?? "", value: hit)
                    return hit
                })
            },
            AtlassianResource(
                fetcher: "jira.issue", reader: "jira_issue",
                summary: "A Jira issue by key: summary, status, type, priority, assignee, reporter, description (as text), labels, components, fix versions, parent, subtasks, linked issues and the latest comments.",
                properties: ["key": issueKey], required: ["key"], key: byKey
            ) { atlassian, input in
                let key = input["key"]?.string ?? ""
                let issue = try await atlassian.get("/rest/api/3/issue/\(key)", query: [URLQueryItem(name: "fields", value: Self.issueFields)], service: "Jira")
                return Self.issueRecord(issue, site: atlassian.siteBase)
            },
            AtlassianResource(
                fetcher: "jira.comments", reader: "jira_issue_comments",
                summary: "A Jira issue's comments, newest first (author, date, text).",
                properties: ["key": JSONSchema.string("Issue key."), "limit": JSONSchema.integer("How many (default 20, at most 100).")],
                required: ["key"], key: byKey
            ) { atlassian, input in
                let key = input["key"]?.string ?? ""
                let result = try await atlassian.get("/rest/api/3/issue/\(key)/comment",
                                                     query: [URLQueryItem(name: "orderBy", value: "-created"), URLQueryItem(name: "maxResults", value: String(Self.limit(input, 20, 100)))],
                                                     service: "Jira")
                return ["key": .string(key), "total": result["total"] ?? .null, "comments": .array((result["comments"]?.array ?? []).map(Self.commentRecord))]
            },
            AtlassianResource(
                fetcher: "jira.changelog", reader: "jira_issue_changelog",
                summary: "A Jira issue's history: who changed which field from what to what, and when (newest first, up to 50 changes).",
                properties: ["key": JSONSchema.string("Issue key.")], required: ["key"], key: byKey
            ) { atlassian, input in
                let key = input["key"]?.string ?? ""
                let result = try await atlassian.get("/rest/api/3/issue/\(key)/changelog", query: [URLQueryItem(name: "maxResults", value: "50")], service: "Jira")
                let changes: [JSONValue] = (result["values"]?.array ?? []).reversed().map { entry in
                    ["author": entry["author"]?["displayName"] ?? .null, "created": entry["created"] ?? .null,
                     "items": .array((entry["items"]?.array ?? []).map { item in
                         ["field": item["field"] ?? .null, "from": item["fromString"] ?? .null, "to": item["toString"] ?? .null]
                     })]
                }
                return ["key": .string(key), "changes": .array(changes)]
            },
            AtlassianResource(
                fetcher: "jira.projects", reader: "jira_projects",
                summary: "Jira projects (key, name, type, lead).",
                properties: [:], key: all
            ) { atlassian, _ in
                let result = try await atlassian.get("/rest/api/3/project/search",
                                                     query: [URLQueryItem(name: "maxResults", value: "100"), URLQueryItem(name: "expand", value: "lead")], service: "Jira")
                return ["projects": .array((result["values"]?.array ?? []).map { project in
                    ["key": project["key"] ?? .null, "name": project["name"] ?? .null,
                     "type": project["projectTypeKey"] ?? .null, "lead": project["lead"]?["displayName"] ?? .null]
                })]
            },
        ]
    }

    /// The input's `limit`, between 1 and `most` (`fallback` when absent).
    nonisolated static func limit(_ input: JSONValue, _ fallback: Int, _ most: Int) -> Int {
        min(max(input["limit"]?.int ?? fallback, 1), most)
    }
}
