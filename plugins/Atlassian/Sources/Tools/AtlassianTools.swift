import DashKit
import DashKitUI
import Foundation

extension AtlassianIntegration {
    private struct SearchInput: Decodable { let query: String; let space: String?; let limit: Int? }
    private struct PageInput: Decodable { let id: String; let fresh: Bool? }
    private struct IssueInput: Decodable { let key: String; let fresh: Bool?; let limit: Int? }
    private struct JQLInput: Decodable { let jql: String; let limit: Int? }
    private struct FreshInput: Decodable { let fresh: Bool? }
    private struct CachedInput: Decodable { let kind: String?; let text: String?; let limit: Int? }

    static let maxText = 60_000
    static let freshProperty = JSONSchema.boolean("Skip the cached copy and read it online now.")

    nonisolated static func validPageID(_ id: String) -> Bool { !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber } }
    nonisolated static func validIssueKey(_ key: String) -> Bool { key.wholeMatch(of: /[A-Z][A-Z0-9_]+-[0-9]+/) != nil }

    private func pageID(_ id: String) throws -> String {
        guard Self.validPageID(id) else { throw ToolError("Page id should be letters and digits, like 123456.") }
        return id
    }

    private func issueKey(_ key: String) throws -> String {
        let key = key.uppercased()
        guard Self.validIssueKey(key) else { throw ToolError("Issue key should look like KAN-1234.") }
        return key
    }

    private var siteBase: String { siteURL?.absoluteString ?? "" }

    private static func cut(_ text: String) -> String {
        text.count > maxText ? String(text.prefix(maxText)) + "\n[truncated]" : text
    }

    var tools: [DashiiTool] { confluenceTools + jiraTools + [cacheTool] }

    // MARK: Confluence

    private var confluenceTools: [DashiiTool] {
        [
            DashiiTool(
                name: "confluence_search",
                description: "Search Confluence pages by text (CQL siteSearch). Call when the user asks about docs, runbooks, designs or decisions that might be written down.",
                properties: ["query": JSONSchema.string("Words to search for."), "space": JSONSchema.string("Optional space key to search in."),
                             "limit": JSONSchema.integer("How many (default 15, at most 50).")],
                required: ["query"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(SearchInput.self)
                var cql = "siteSearch ~ \"\(request.query.replacingOccurrences(of: "\"", with: "\\\""))\" AND type = page"
                if let space = request.space, !space.isEmpty { cql += " AND space = \"\(space.replacingOccurrences(of: "\"", with: ""))\"" }
                let result = try await get(
                    "/wiki/rest/api/search",
                    query: [URLQueryItem(name: "cql", value: cql), URLQueryItem(name: "limit", value: String(min(max(request.limit ?? 15, 1), 50)))],
                    service: "Confluence")
                let hits: [JSONValue] = (result["results"]?.array ?? []).map { item in
                    ["id": item["content"]?["id"] ?? .null, "title": item["content"]?["title"] ?? item["title"] ?? .null,
                     "space": item["resultGlobalContainer"]?["title"] ?? .null, "excerpt": item["excerpt"] ?? .null,
                     "url": .string(siteBase + "/wiki" + (item["url"]?.string ?? ""))]
                }
                for hit in hits { if let id = hit["id"]?.string { remember("confluence.hit", key: id, value: hit) } }
                return Sanitizer.clean(.array(hits))
            },
            DashiiTool(
                name: "confluence_get_page",
                description: "Read a Confluence page by id (from confluence_search): title, space, version, last update, labels, ancestors (breadcrumb) and the body as Markdown (cut at 60,000 characters). Reuses a recent copy unless fresh is true.",
                properties: ["id": JSONSchema.string("Page id."), "fresh": Self.freshProperty], required: ["id"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(PageInput.self)
                let id = try pageID(request.id)
                return try await cached("confluence.page", key: id, fresh: request.fresh ?? false) {
                    let page = try await self.get("/wiki/rest/api/content/\(id)",
                                                  query: [URLQueryItem(name: "expand", value: "body.storage,version,space,ancestors,metadata.labels")],
                                                  service: "Confluence")
                    return Self.pageRecord(page, site: self.siteBase)
                }
            },
            DashiiTool(
                name: "confluence_page_children",
                description: "The child pages of a Confluence page (id, title), e.g. to walk a runbook section.",
                properties: ["id": JSONSchema.string("Parent page id."), "fresh": Self.freshProperty], required: ["id"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(PageInput.self)
                let id = try pageID(request.id)
                return try await cached("confluence.children", key: id, fresh: request.fresh ?? false) {
                    let result = try await self.get("/wiki/rest/api/content/\(id)/child/page", query: [URLQueryItem(name: "limit", value: "100")], service: "Confluence")
                    return ["page_id": .string(id), "children": .array((result["results"]?.array ?? []).map { child in
                        ["id": child["id"] ?? .null, "title": child["title"] ?? .null,
                         "url": .string(self.siteBase + "/wiki" + (child["_links"]?["webui"]?.string ?? ""))]
                    })]
                }
            },
            DashiiTool(
                name: "confluence_page_attachments",
                description: "Attachments of a Confluence page: file name, type, size, last update and download link (metadata only, files aren't downloaded).",
                properties: ["id": JSONSchema.string("Page id."), "fresh": Self.freshProperty], required: ["id"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(PageInput.self)
                let id = try pageID(request.id)
                return try await cached("confluence.attachments", key: id, fresh: request.fresh ?? false) {
                    let result = try await self.get("/wiki/rest/api/content/\(id)/child/attachment",
                                                    query: [URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "expand", value: "version")], service: "Confluence")
                    return ["page_id": .string(id), "attachments": .array((result["results"]?.array ?? []).map { item in
                        ["title": item["title"] ?? .null, "media_type": item["metadata"]?["mediaType"] ?? item["extensions"]?["mediaType"] ?? .null,
                         "size": item["extensions"]?["fileSize"] ?? .null, "updated": item["version"]?["when"] ?? .null,
                         "download": .string(self.siteBase + "/wiki" + (item["_links"]?["download"]?.string ?? ""))]
                    })]
                }
            },
            DashiiTool(
                name: "confluence_spaces",
                description: "Confluence spaces (key, name, type), to know where to search.",
                properties: ["fresh": Self.freshProperty]
            ) { [weak self] input in
                guard let self else { return nil }
                return try await cached("confluence.spaces", key: "all", fresh: try input.toolInput(FreshInput.self).fresh ?? false) {
                    let result = try await self.get("/wiki/rest/api/space", query: [URLQueryItem(name: "limit", value: "250")], service: "Confluence")
                    return ["spaces": .array((result["results"]?.array ?? []).map { space in
                        ["key": space["key"] ?? .null, "name": space["name"] ?? .null, "type": space["type"] ?? .null]
                    })]
                }
            },
        ]
    }

    /// What's stored for a Confluence page.
    static func pageRecord(_ page: JSONValue, site: String) -> JSONValue {
        let markdown = AtlassianFormats.markdown(fromStorage: page["body"]?["storage"]?["value"]?.string ?? "")
        return ["id": page["id"] ?? .null, "title": page["title"] ?? .null,
                "space": ["key": page["space"]?["key"] ?? .null, "name": page["space"]?["name"] ?? .null],
                "version": page["version"]?["number"] ?? .null, "updated": page["version"]?["when"] ?? .null,
                "updated_by": page["version"]?["by"]?["displayName"] ?? .null,
                "url": .string(site + "/wiki" + (page["_links"]?["webui"]?.string ?? "")),
                "labels": .array((page["metadata"]?["labels"]?["results"]?.array ?? []).compactMap { $0["name"] }),
                "ancestors": .array((page["ancestors"]?.array ?? []).map { ["id": $0["id"] ?? .null, "title": $0["title"] ?? .null] }),
                "markdown": .string(cut(markdown))]
    }

    // MARK: Jira

    static let issueFields = "summary,status,assignee,reporter,priority,issuetype,description,created,updated,labels,components,fixVersions,parent,subtasks,issuelinks,comment"
    static let hitFields: JSONValue = ["summary", "status", "assignee", "priority", "issuetype", "updated"]

    private var jiraTools: [DashiiTool] {
        [
            DashiiTool(
                name: "jira_myself_issues",
                description: "List the open Jira issues assigned to the signed-in user (not Done), most recently updated first, up to 50. Returns key, summary, status and url.",
                properties: [:]
            ) { [weak self] _ in
                guard let self else { return nil }
                let result = try await post("/rest/api/3/search/jql", body: Self.myIssuesBody, service: "Jira")
                return Sanitizer.clean(.array((result["issues"]?.array ?? []).map { issue in
                    let hit = Self.hitRecord(issue, site: siteBase)
                    remember("jira.hit", key: hit["key"]?.string ?? "", value: hit)
                    return ["key": hit["key"] ?? .null, "summary": hit["summary"] ?? .null, "status": hit["status"] ?? .null, "url": hit["url"] ?? .null]
                }))
            },
            DashiiTool(
                name: "jira_jql_search",
                description: "Search Jira with JQL (read-only), e.g. project = KAN AND status = \"In Progress\" ORDER BY updated DESC. Returns key, summary, status, type, priority, assignee, updated and url, up to 50.",
                properties: ["jql": JSONSchema.string("JQL query."), "limit": JSONSchema.integer("How many (default 25, at most 50).")],
                required: ["jql"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(JQLInput.self)
                let result = try await post("/rest/api/3/search/jql",
                                            body: ["jql": .string(request.jql), "fields": Self.hitFields, "maxResults": .number(Double(min(max(request.limit ?? 25, 1), 50)))],
                                            service: "Jira")
                return Sanitizer.clean(.array((result["issues"]?.array ?? []).map { issue in
                    let hit = Self.hitRecord(issue, site: siteBase)
                    remember("jira.hit", key: hit["key"]?.string ?? "", value: hit)
                    return hit
                }))
            },
            DashiiTool(
                name: "jira_issue",
                description: "Read a Jira issue by key: summary, status, type, priority, assignee, reporter, description (as text), labels, components, fix versions, parent, subtasks, linked issues and the latest comments. Reuses a recent copy unless fresh is true.",
                properties: ["key": JSONSchema.string("Issue key, e.g. KAN-1234."), "fresh": Self.freshProperty], required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(IssueInput.self)
                let key = try issueKey(request.key)
                return try await cached("jira.issue", key: key, fresh: request.fresh ?? false) {
                    let issue = try await self.get("/rest/api/3/issue/\(key)", query: [URLQueryItem(name: "fields", value: Self.issueFields)], service: "Jira")
                    return Self.issueRecord(issue, site: self.siteBase)
                }
            },
            DashiiTool(
                name: "jira_issue_comments",
                description: "A Jira issue's comments, newest first (author, date, text).",
                properties: ["key": JSONSchema.string("Issue key."), "limit": JSONSchema.integer("How many (default 20, at most 100)."), "fresh": Self.freshProperty],
                required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(IssueInput.self)
                let key = try issueKey(request.key)
                let limit = min(max(request.limit ?? 20, 1), 100)
                return try await cached("jira.comments", key: key, fresh: request.fresh ?? false) {
                    let result = try await self.get("/rest/api/3/issue/\(key)/comment",
                                                    query: [URLQueryItem(name: "orderBy", value: "-created"), URLQueryItem(name: "maxResults", value: String(limit))],
                                                    service: "Jira")
                    return ["key": .string(key), "total": result["total"] ?? .null, "comments": .array((result["comments"]?.array ?? []).map(Self.commentRecord))]
                }
            },
            DashiiTool(
                name: "jira_issue_changelog",
                description: "A Jira issue's history: who changed which field from what to what, and when (newest first, up to 50 changes).",
                properties: ["key": JSONSchema.string("Issue key."), "fresh": Self.freshProperty], required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(IssueInput.self)
                let key = try issueKey(request.key)
                return try await cached("jira.changelog", key: key, fresh: request.fresh ?? false) {
                    let result = try await self.get("/rest/api/3/issue/\(key)/changelog", query: [URLQueryItem(name: "maxResults", value: "50")], service: "Jira")
                    let changes: [JSONValue] = (result["values"]?.array ?? []).reversed().map { entry in
                        ["author": entry["author"]?["displayName"] ?? .null, "created": entry["created"] ?? .null,
                         "items": .array((entry["items"]?.array ?? []).map { item in
                             ["field": item["field"] ?? .null, "from": item["fromString"] ?? .null, "to": item["toString"] ?? .null]
                         })]
                    }
                    return ["key": .string(key), "changes": .array(changes)]
                }
            },
            DashiiTool(
                name: "jira_projects",
                description: "Jira projects (key, name, type, lead).",
                properties: ["fresh": Self.freshProperty]
            ) { [weak self] input in
                guard let self else { return nil }
                return try await cached("jira.projects", key: "all", fresh: try input.toolInput(FreshInput.self).fresh ?? false) {
                    let result = try await self.get("/rest/api/3/project/search",
                                                    query: [URLQueryItem(name: "maxResults", value: "100"), URLQueryItem(name: "expand", value: "lead")], service: "Jira")
                    return ["projects": .array((result["values"]?.array ?? []).map { project in
                        ["key": project["key"] ?? .null, "name": project["name"] ?? .null,
                         "type": project["projectTypeKey"] ?? .null, "lead": project["lead"]?["displayName"] ?? .null]
                    })]
                }
            },
        ]
    }

    /// A search hit's summary.
    static func hitRecord(_ issue: JSONValue, site: String) -> JSONValue {
        let key = issue["key"]?.string ?? ""
        let fields = issue["fields"]
        return ["key": .string(key), "summary": fields?["summary"] ?? .null, "status": fields?["status"]?["name"] ?? .null,
                "type": fields?["issuetype"]?["name"] ?? .null, "priority": fields?["priority"]?["name"] ?? .null,
                "assignee": fields?["assignee"]?["displayName"] ?? .null, "updated": fields?["updated"] ?? .null,
                "url": .string(site + "/browse/" + key)]
    }

    /// What's stored for a Jira issue.
    static func issueRecord(_ issue: JSONValue, site: String) -> JSONValue {
        let fields = issue["fields"]
        let links: [JSONValue] = (fields?["issuelinks"]?.array ?? []).compactMap { link in
            let outward = link["outwardIssue"] != nil
            guard let other = link["outwardIssue"] ?? link["inwardIssue"] else { return nil }
            return ["relation": (outward ? link["type"]?["outward"] : link["type"]?["inward"]) ?? .null,
                    "key": other["key"] ?? .null, "summary": other["fields"]?["summary"] ?? .null,
                    "status": other["fields"]?["status"]?["name"] ?? .null]
        }
        let comments = (fields?["comment"]?["comments"]?.array ?? []).suffix(10).reversed().map(commentRecord)
        return hitRecord(issue, site: site).merging([
            "reporter": fields?["reporter"]?["displayName"] ?? .null, "created": fields?["created"] ?? .null,
            "description": .string(cut(AtlassianFormats.text(fromADF: fields?["description"]))),
            "labels": fields?["labels"] ?? .array([]),
            "components": .array((fields?["components"]?.array ?? []).compactMap { $0["name"] }),
            "fix_versions": .array((fields?["fixVersions"]?.array ?? []).compactMap { $0["name"] }),
            "parent": fields?["parent"].map { ["key": $0["key"] ?? .null, "summary": $0["fields"]?["summary"] ?? .null] } ?? .null,
            "subtasks": .array((fields?["subtasks"]?.array ?? []).map { ["key": $0["key"] ?? .null, "summary": $0["fields"]?["summary"] ?? .null,
                                                                       "status": $0["fields"]?["status"]?["name"] ?? .null] }),
            "links": .array(links),
            "comment_count": fields?["comment"]?["total"] ?? .null,
            "latest_comments": .array(Array(comments)),
        ])
    }

    static func commentRecord(_ comment: JSONValue) -> JSONValue {
        let text = AtlassianFormats.text(fromADF: comment["body"])
        return ["author": comment["author"]?["displayName"] ?? .null, "created": comment["created"] ?? .null,
                "text": .string(text.count > 4000 ? String(text.prefix(4000)) + "…" : text)]
    }

    // MARK: Offline lookup

    private var cacheTool: DashiiTool {
        DashiiTool(
            name: "atlassian_cached",
            description: "What's already mirrored from Jira and Confluence on this Mac (pages and issues read before, search hits, lists), searchable by text, without going online. Use it when offline or to find something read earlier.",
            properties: ["kind": JSONSchema.string("Only this kind.", enum: Self.cacheKinds.map(\.kind)),
                         "text": JSONSchema.string("Words to look for (title, key, summary, body)."),
                         "limit": JSONSchema.integer("How many (default 20, at most 100).")]
        ) { [weak self] input in
            guard let self else { return nil }
            let request = try input.toolInput(CachedInput.self)
            let kinds = request.kind.map { [$0] } ?? Self.cacheKinds.map(\.kind)
            let words = (request.text ?? "").lowercased().split(separator: " ").map(String.init)
            let records = kinds.flatMap { mirror?.records(kind: $0, scope: cacheScope) ?? [] }
                .filter { record in
                    guard !words.isEmpty else { return true }
                    let haystack = (record.key + " " + record.value.jsonString()).lowercased()
                    return words.allSatisfy(haystack.contains)
                }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(min(max(request.limit ?? 20, 1), 100))
            return .array(records.map { record in
                let value = record.value
                return ["kind": .string(record.kind), "key": .string(record.key),
                        "title": value["title"] ?? value["summary"] ?? .null, "status": value["status"] ?? .null,
                        "url": value["url"] ?? .null, "synced_at": .string(record.updatedAt.formatted(.iso8601))]
            })
        }
    }
}
