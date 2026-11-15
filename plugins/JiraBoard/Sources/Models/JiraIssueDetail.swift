import DashKit
import Foundation

/// Everything the issue view shows, read from one `GET issue?fields=*all&expand=names`: the
/// description and comments as Atlassian Document Format (drawn by `ADFView`), sub-tasks, linked
/// issues, the details sidebar, and the site's custom fields by their display names.
struct JiraIssueDetail: Sendable {
    /// Another issue as the view lists it: parent, sub-task or link.
    struct Related: Sendable, Hashable, Identifiable {
        var relation = ""
        let key: String
        let summary: String
        let status: String
        let statusCategory: String
        let type: String?
        let priority: String?
        let assignee: String?
        var id: String { relation + key }

        init(json: JSONValue, relation: String = "") {
            let fields = json["fields"] ?? .null
            self.relation = relation
            key = json["key"]?.string ?? ""
            summary = fields["summary"]?.string ?? ""
            status = fields["status"]?["name"]?.string ?? ""
            statusCategory = fields["status"]?["statusCategory"]?["key"]?.string ?? ""
            type = fields["issuetype"]?["name"]?.string
            priority = fields["priority"]?["name"]?.string
            assignee = fields["assignee"]?["displayName"]?.string
        }
    }

    struct Comment: Sendable, Identifiable {
        let id: String
        let author: String
        var authorID = ""
        let created: Date?
        var edited: Bool = false
        let body: JSONValue
    }

    /// One acceptance criterion: its blocks (nested lists kept), and its state when Jira holds
    /// one (an action item ticked or not).
    struct Criterion: Sendable, Identifiable {
        let id: Int
        let content: [JSONValue]
        var done: Bool?
    }

    /// A custom field the site added, with a readable value.
    struct Field: Sendable, Hashable, Identifiable {
        /// The field's key ("customfield_10042"): sites often have several fields with one name.
        let id: String
        let name: String
        let value: String
    }

    let issue: JiraClient.Issue
    let url: URL
    let project: String
    let reporter: String?
    /// The description without its acceptance criteria, which `criteria` holds.
    let description: JSONValue
    let criteria: [Criterion]
    let parent: Related?
    let subtasks: [Related]
    let links: [Related]
    /// Newest first.
    let comments: [Comment]
    let components: [String]
    let fixVersions: [String]
    let sprint: String?
    let storyPoints: String?
    let due: String?
    let created: Date?
    let fields: [Field]

    /// `latestComments`, newest first, replaces the issue's own comment page when the issue has
    /// more comments than that page holds (it holds the oldest).
    init(json: JSONValue, url: URL, latestComments: [JSONValue]? = nil) {
        let fields = json["fields"] ?? .null
        let names = json["names"]?.object ?? [:]
        issue = JiraClient.Issue(json: json)
        self.url = url
        project = fields["project"]?["name"]?.string ?? ""
        reporter = fields["reporter"]?["displayName"]?.string
        let (rest, fromDescription) = Self.splitCriteria(fields["description"] ?? .null)
        parent = fields["parent"].flatMap { $0["key"]?.string == nil ? nil : Related(json: $0) }
        subtasks = fields["subtasks"]?.array?.map { Related(json: $0) } ?? []
        links = fields["issuelinks"]?.array?.compactMap { link in
            if let issue = link["outwardIssue"] { return Related(json: issue, relation: link["type"]?["outward"]?.string ?? "relates to") }
            if let issue = link["inwardIssue"] { return Related(json: issue, relation: link["type"]?["inward"]?.string ?? "relates to") }
            return nil
        } ?? []
        let newestFirst = latestComments ?? Array((fields["comment"]?["comments"]?.array ?? []).reversed())
        comments = newestFirst.enumerated().map { index, comment in
            Comment(id: comment["id"]?.string ?? "\(index)", author: comment["author"]?["displayName"]?.string ?? "Someone",
                    authorID: comment["author"]?["accountId"]?.string ?? "",
                    created: ISO8601DateFormatter.date(comment["created"]?.string),
                    edited: comment["updated"]?.string != nil && comment["updated"]?.string != comment["created"]?.string,
                    body: comment["body"] ?? .null)
        }
        components = fields["components"]?.array?.compactMap { $0["name"]?.string } ?? []
        fixVersions = fields["fixVersions"]?.array?.compactMap { $0["name"]?.string } ?? []
        due = fields["duedate"]?.string
        created = ISO8601DateFormatter.date(fields["created"]?.string)

        // Custom fields, named by the site: story points and sprint have their own rows.
        var sprint: String?
        var points: String?
        var custom: [Field] = []
        var criteriaField: JSONValue?
        // In key order, so when two fields match (two "Acceptance Criteria") the same one wins every time.
        for (id, value) in (fields.object ?? [:]).sorted(by: { $0.key < $1.key }) where id.hasPrefix("customfield_") {
            guard let name = names[id]?.string else { continue }
            let lower = name.lowercased()
            if lower == "sprint" {
                let sprints = value.array ?? []
                sprint = (sprints.first { $0["state"]?.string == "active" } ?? sprints.last)?["name"]?.string
            } else if lower.contains("acceptance criteria"), value != .null, criteriaField == nil {
                criteriaField = value
            } else if lower.contains("story point") {
                if points == nil, let text = Self.display(value) { points = text }
            } else if !Self.skipped.contains(lower), let text = Self.display(value) {
                custom.append(Field(id: id, name: name, value: text))
            }
        }
        self.sprint = sprint
        // A site's own "Acceptance Criteria" field wins; otherwise the description's section.
        let field = criteriaField.map { value in
            value["type"]?.string == "doc" ? Self.criteria(in: value["content"]?.array ?? [])
                : (value.string ?? "").split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "-*• \t")) }
                    .filter { !$0.isEmpty }
                    .map { line in ["type": "paragraph", "content": [["type": "text", "text": .string(line)]]] as JSONValue }
                    .enumerated().map { Criterion(id: $0, content: [$1]) }
        } ?? []
        criteria = field.isEmpty ? fromDescription : field
        description = field.isEmpty ? rest : fields["description"] ?? .null
        storyPoints = points
        self.fields = custom.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Acceptance criteria

    /// The description with its "Acceptance criteria" section taken out, and that section's items.
    /// The section starts at a heading or a bold line naming it and runs to the next heading or
    /// bold title line.
    static func splitCriteria(_ document: JSONValue) -> (JSONValue, [Criterion]) {
        guard var object = document.object, let blocks = document["content"]?.array,
              let start = blocks.firstIndex(where: { title(of: $0).map(isCriteriaTitle) == true }) else { return (document, []) }
        let end = blocks[(start + 1)...].firstIndex { title(of: $0) != nil } ?? blocks.endIndex
        let items = criteria(in: Array(blocks[(start + 1)..<end]))
        guard !items.isEmpty else { return (document, []) }
        object["content"] = .array(Array(blocks[..<start] + blocks[end...]))
        return (.object(object), items)
    }

    /// Lists become one criterion per item; task lists keep their ticks; paragraphs count alone.
    static func criteria(in blocks: [JSONValue]) -> [Criterion] {
        var items: [Criterion] = []
        for block in blocks {
            switch block["type"]?.string {
            case "bulletList", "orderedList":
                for item in block["content"]?.array ?? [] { items.append(Criterion(id: items.count, content: item["content"]?.array ?? [])) }
            case "taskList":
                for item in block["content"]?.array ?? [] {
                    items.append(Criterion(id: items.count, content: [["type": "paragraph", "content": item["content"] ?? []]],
                                           done: item["attrs"]?["state"]?.string == "DONE"))
                }
            case "paragraph":
                if !(block["content"]?.array ?? []).isEmpty { items.append(Criterion(id: items.count, content: [block])) }
            default:
                items.append(Criterion(id: items.count, content: [block]))
            }
        }
        return items
    }

    /// A block's text when it reads as a section title: a heading, or a short paragraph all in bold.
    static func title(of block: JSONValue) -> String? {
        let inline = block["content"]?.array ?? []
        let text = inline.compactMap { $0["text"]?.string }.joined().trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if block["type"]?.string == "heading" { return text }
        let bold = inline.allSatisfy { node in
            node["type"]?.string == "hardBreak" || (node["marks"]?.array ?? []).contains { $0["type"]?.string == "strong" }
                || node["text"]?.string?.trimmingCharacters(in: .whitespaces).isEmpty == true
        }
        return block["type"]?.string == "paragraph" && bold && text.count < 80 ? text : nil
    }

    static func isCriteriaTitle(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        return ["acceptance criteria", "acceptance criterion", "critères d'acceptation", "criteres d'acceptation", "definition of done"]
            .contains { lower.hasPrefix($0) } || lower == "ac"
    }

    /// Internal fields with no meaning to a reader.
    private static let skipped: Set<String> = ["rank", "development", "team", "flagged", "issue color", "epic color", "epic status",
                                               "vulnerability", "design", "request participants", "satisfaction"]

    /// A field value as short text: strings, numbers, options, users, and lists of them. Nil for
    /// rich text, internal blobs and empty values.
    static func display(_ value: JSONValue) -> String? {
        switch value {
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.contains("com.atlassian"), trimmed.count < 200 else { return nil }
            return trimmed
        case .number(let number):
            // Int(exactly:) is nil for huge or infinite values, which Int() would trap on.
            return Int(exactly: number).map(String.init) ?? String(number)
        case .bool(let flag):
            return flag ? "Yes" : "No"
        case .array(let items):
            let texts = items.compactMap(display)
            return texts.isEmpty ? nil : texts.joined(separator: ", ")
        case .object:
            if value["type"]?.string == "doc" { return nil }
            for key in ["displayName", "value", "name"] {
                if let text = value[key]?.string, !text.isEmpty {
                    if let child = value["child"]?["value"]?.string { return "\(text) › \(child)" }
                    return text
                }
            }
            return nil
        default:
            return nil
        }
    }
}

extension JiraClient {
    /// The issue view's data: every field, with the site's field names.
    func issueView(_ key: String) async throws -> JiraIssueDetail {
        let json = try await issueJSON(key)
        let page = json["fields"]?["comment"]
        let latest = (page?["total"]?.int ?? 0) > (page?["comments"]?.array?.count ?? 0) ? try? await latestComments(key) : nil
        return JiraIssueDetail(json: json, url: browseURL(key), latestComments: latest)
    }
}
