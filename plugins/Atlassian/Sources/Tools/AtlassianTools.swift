import DashKit
import DashKitUI
import Foundation

/// What Dashii gets from Jira and Confluence: readers of what Dash fetched (see `resources`), and
/// `atlassian_cached` to search everything stored. All read Dash's mirror; none goes online.
extension AtlassianIntegration {
    private struct CachedInput: Decodable { let kind: String?; let text: String?; let limit: Int? }

    static let maxText = 60_000

    nonisolated static func validPageID(_ id: String) -> Bool { !id.isEmpty && id.allSatisfy { $0.isLetter || $0.isNumber } }
    nonisolated static func validIssueKey(_ key: String) -> Bool { key.wholeMatch(of: /[A-Z][A-Z0-9_]+-[0-9]+/) != nil }

    var siteBase: String { siteURL?.absoluteString ?? "" }

    private static func cut(_ text: String) -> String {
        text.count > maxText ? String(text.prefix(maxText)) + "\n[truncated]" : text
    }

    var tools: [DashiiTool] { readers + [cacheTool] }

    // MARK: Confluence

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
            properties: ["kind": JSONSchema.string("Only this kind.", enum: Self.lookupKinds),
                         "text": JSONSchema.string("Words to look for (title, key, summary, body)."),
                         "limit": JSONSchema.integer("How many (default 20, at most 100).")]
        ) { [weak self] input in
            guard let self else { return nil }
            let request = try input.toolInput(CachedInput.self)
            let kinds = request.kind.map { [$0] } ?? Self.lookupKinds
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
