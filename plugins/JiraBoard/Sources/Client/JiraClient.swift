import DashKit
import Foundation

/// Jira Cloud REST client over the `atlassian` integration's connection.
struct JiraClient: Sendable {
    let connection: IntegrationConnection
    var site: URL { connection.baseURL }

    init(connection: IntegrationConnection) {
        self.connection = connection
    }

    static let issueFields = ["summary", "status", "assignee", "reporter", "priority", "issuetype", "updated", "labels", "parent"]

    struct Issue: Sendable, Equatable {
        /// Jira's numeric id (the development panel is looked up by it).
        var id: String = ""
        let key: String
        let summary: String
        let statusID: String
        let statusName: String
        let statusCategory: String
        let assignee: String?
        let priority: String?
        let issueType: String?
        let updated: Date?
        let labels: [String]

        init(json: JSONValue) {
            let fields = json["fields"] ?? .null
            id = json["id"]?.string ?? ""
            key = json["key"]?.string ?? ""
            summary = fields["summary"]?.string ?? ""
            statusID = fields["status"]?["id"]?.string ?? ""
            statusName = fields["status"]?["name"]?.string ?? ""
            statusCategory = fields["status"]?["statusCategory"]?["key"]?.string ?? ""
            assignee = fields["assignee"]?["displayName"]?.string
            priority = fields["priority"]?["name"]?.string
            issueType = fields["issuetype"]?["name"]?.string
            updated = ISO8601DateFormatter.date(fields["updated"]?.string)
            labels = fields["labels"]?.array?.compactMap(\.string) ?? []
        }
    }

    struct Column: Sendable, Hashable, Codable {
        let name: String
        let statusIDs: [String]
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: site.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func send(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: JSONValue? = nil) async throws -> JSONValue {
        let request = try HTTP.request(url(path, query: query), method: method, body: body, headers: ["Accept": "application/json"])
        let (data, _) = try await connection.send(request, service: "Jira")
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    /// The issue's linked pull requests from Jira's development panel (GitHub/GitLab apps):
    /// how many, and the overall state (OPEN, MERGED, DECLINED). Read-only.
    func pullRequests(issueID: String) async throws -> (count: Int, state: String?) {
        let summary = try await send("rest/dev-status/latest/issue/summary", query: [URLQueryItem(name: "issueId", value: issueID)])
        let overall = summary["summary"]?["pullrequest"]?["overall"]
        return (overall?["count"]?.int ?? 0, overall?["state"]?.string)
    }

    func browseURL(_ key: String) -> URL { site.appending(path: "browse/\(key)") }

    /// Enhanced JQL search, following `nextPageToken` up to `limit` issues.
    func search(_ jql: String, limit: Int = 200) async throws -> [Issue] {
        var issues: [Issue] = []
        var token: String?
        repeat {
            var body: [String: JSONValue] = [
                "jql": .string(jql), "maxResults": .number(Double(min(100, limit - issues.count))),
                "fields": .array(Self.issueFields.map { .string($0) }),
            ]
            if let token { body["nextPageToken"] = .string(token) }
            let page = try await send("rest/api/3/search/jql", method: "POST", body: .object(body))
            issues += page["issues"]?.array?.map(Issue.init) ?? []
            token = page["nextPageToken"]?.string
        } while token != nil && issues.count < limit
        return Array(issues.prefix(limit))
    }

    struct BoardInfo: Sendable, Hashable, Identifiable {
        let id: Int
        let name: String
        let type: String
        let project: String
    }

    /// Boards the user can see, optionally filtered by name.
    func boards(matching name: String = "") async throws -> [BoardInfo] {
        var query = [URLQueryItem(name: "maxResults", value: "50")]
        if !name.isEmpty { query.append(URLQueryItem(name: "name", value: name)) }
        let page = try await send("rest/agile/1.0/board", query: query)
        return page["values"]?.array?.compactMap { board in
            guard let id = board["id"]?.int else { return nil }
            return BoardInfo(id: id, name: board["name"]?.string ?? "Board \(id)", type: board["type"]?.string ?? "",
                             project: board["location"]?["projectKey"]?.string ?? "")
        } ?? []
    }

    func boardColumns(_ boardID: Int) async throws -> [Column] {
        let configuration = try await send("rest/agile/1.0/board/\(boardID)/configuration")
        return configuration["columnConfig"]?["columns"]?.array?.map { column in
            Column(
                name: column["name"]?.string ?? "",
                statusIDs: column["statuses"]?.array?.compactMap { $0["id"]?.string } ?? [])
        } ?? []
    }

    /// Issues in the board's active sprint (scrum), or its open/recent issues (kanban).
    func boardIssues(_ boardID: Int) async throws -> [Issue] {
        let fields = URLQueryItem(name: "fields", value: Self.issueFields.joined(separator: ","))
        let sprints = try? await send("rest/agile/1.0/board/\(boardID)/sprint", query: [URLQueryItem(name: "state", value: "active")])
        if let sprintIDs = sprints?["values"]?.array?.compactMap({ $0["id"]?.int }), !sprintIDs.isEmpty {
            var issues: [Issue] = []
            for sprint in sprintIDs {
                let page = try await send(
                    "rest/agile/1.0/board/\(boardID)/sprint/\(sprint)/issue",
                    query: [URLQueryItem(name: "maxResults", value: "200"), fields])
                issues += page["issues"]?.array?.map(Issue.init) ?? []
            }
            return issues
        }
        let page = try await send(
            "rest/agile/1.0/board/\(boardID)/issue",
            query: [URLQueryItem(name: "jql", value: "statusCategory != Done OR resolved >= -14d"),
                    URLQueryItem(name: "maxResults", value: "200"), fields])
        return page["issues"]?.array?.map(Issue.init) ?? []
    }

    /// Full issue with description and recent comments as plain text.
    func issueDetail(_ key: String) async throws -> JSONValue {
        let issue = try await send(
            "rest/api/3/issue/\(key)",
            query: [URLQueryItem(name: "fields", value: (Self.issueFields + ["description", "comment"]).joined(separator: ","))])
        let fields = issue["fields"] ?? .null
        let comments: [JSONValue] = (fields["comment"]?["comments"]?.array ?? []).suffix(15).map { comment in
            ["author": .string(comment["author"]?["displayName"]?.string ?? "?"),
             "created": comment["created"] ?? .null,
             "body": .string(Self.plainText(comment["body"]))]
        }
        let summary = Issue(json: issue)
        return [
            "key": .string(key), "summary": .string(summary.summary), "status": .string(summary.statusName),
            "type": .string(summary.issueType ?? ""), "priority": .string(summary.priority ?? ""),
            "assignee": .string(summary.assignee ?? "Unassigned"),
            "reporter": .string(fields["reporter"]?["displayName"]?.string ?? ""),
            "labels": .array(summary.labels.map { .string($0) }),
            "parent": .string(fields["parent"]?["key"]?.string ?? ""),
            "url": .string(browseURL(key).absoluteString),
            "description": .string(Self.plainText(fields["description"])),
            "comments": .array(comments),
        ]
    }

    /// The raw issue with every field and the site's field names (`names`).
    func issueJSON(_ key: String) async throws -> JSONValue {
        try await send("rest/api/3/issue/\(key)", query: [URLQueryItem(name: "fields", value: "*all"), URLQueryItem(name: "expand", value: "names")])
    }

    /// The newest comments, newest first: the issue itself only carries the oldest page.
    func latestComments(_ key: String, limit: Int = 100) async throws -> [JSONValue] {
        try await send("rest/api/3/issue/\(key)/comment",
                       query: [URLQueryItem(name: "orderBy", value: "-created"), URLQueryItem(name: "maxResults", value: "\(limit)")])["comments"]?.array ?? []
    }

    func transitions(_ key: String) async throws -> [(id: String, name: String)] {
        let result = try await send("rest/api/3/issue/\(key)/transitions")
        return result["transitions"]?.array?.compactMap { item in
            guard let id = item["id"]?.string, let name = item["name"]?.string else { return nil }
            return (id, name)
        } ?? []
    }

    func transition(_ key: String, to transitionID: String) async throws {
        _ = try await send("rest/api/3/issue/\(key)/transitions", method: "POST", body: ["transition": ["id": .string(transitionID)]])
    }

    func comment(_ key: String, text: String) async throws {
        try await comment(key, document: Self.document(text))
    }

    /// Posts a comment written as Atlassian Document Format (a reply with a mention and a quote).
    func comment(_ key: String, document: JSONValue) async throws {
        _ = try await send("rest/api/3/issue/\(key)/comment", method: "POST", body: ["body": document])
    }

    func editComment(_ key: String, id: String, text: String) async throws {
        _ = try await send("rest/api/3/issue/\(key)/comment/\(id)", method: "PUT", body: ["body": Self.document(text)])
    }

    func deleteComment(_ key: String, id: String) async throws {
        _ = try await send("rest/api/3/issue/\(key)/comment/\(id)", method: "DELETE")
    }

    /// The signed-in user's account id (whose comments can be edited).
    func myAccountID() async throws -> String {
        try await send("rest/api/3/myself")["accountId"]?.string ?? ""
    }

    /// A reaction on a comment: an emoji (Atlassian's id is the Unicode code point in hex), how
    /// many people chose it, and whether the user did.
    struct Reaction: Sendable, Hashable {
        let emojiID: String
        var count: Int
        var mine: Bool
        var emoji: String { Self.emoji(emojiID) }

        static func emoji(_ id: String) -> String {
            String(String.UnicodeScalarView(id.split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }))
        }

        static let choices = ["1f44d", "1f44f", "1f525", "2764", "1f604", "1f440", "2705", "1f64f"]
    }

    /// Reactions on comments, by comment id. Jira's reactions service is the one its web app
    /// uses (not part of the documented REST API), so callers treat a failure as "no reactions".
    func reactions(commentIDs: [String]) async throws -> [String: [Reaction]] {
        guard !commentIDs.isEmpty else { return [:] }
        let result = try await send("rest/reactions/1.0/reactions/view",
                                    query: [URLQueryItem(name: "commentIds", value: commentIDs.joined(separator: ","))])
        var byComment: [String: [Reaction]] = [:]
        for item in result.array ?? result["reactions"]?.array ?? [] {
            guard let comment = item["commentId"]?.string ?? item["commentId"]?.int.map(String.init),
                  let emoji = item["emojiId"]?.string else { continue }
            byComment[comment, default: []].append(Reaction(emojiID: emoji, count: item["count"]?.int ?? 1, mine: item["reacted"]?.bool ?? false))
        }
        return byComment
    }

    func react(commentID: String, emojiID: String) async throws {
        _ = try await send("rest/reactions/1.0/reactions", method: "POST", body: ["commentId": .string(commentID), "emojiId": .string(emojiID)])
    }

    func unreact(commentID: String, emojiID: String) async throws {
        _ = try await send("rest/reactions/1.0/reactions/\(commentID)/\(emojiID)", method: "DELETE")
    }

    /// Plain text as a document: one paragraph per blank-line-separated block, lines kept.
    static func document(_ text: String) -> JSONValue {
        let paragraphs: [JSONValue] = text.components(separatedBy: "\n\n").map { paragraph in
            let lines = paragraph.components(separatedBy: "\n")
            var content: [JSONValue] = []
            for (index, line) in lines.enumerated() {
                if index > 0 { content.append(["type": "hardBreak"]) }
                if !line.isEmpty { content.append(["type": "text", "text": .string(line)]) }
            }
            return ["type": "paragraph", "content": .array(content)]
        }
        return ["type": "doc", "version": 1, "content": .array(paragraphs)]
    }

    /// A reply: the quoted start of the comment (when it has text), then a mention of its author
    /// and the text, with its paragraphs and line breaks.
    static func reply(to authorID: String, name: String, quoting quote: String, text: String) -> JSONValue {
        let excerpt = quote.count > 240 ? String(quote.prefix(240)) + "…" : quote
        let mention: [JSONValue] = authorID.isEmpty
            ? [["type": "text", "text": .string("@\(name) ")]]
            : [["type": "mention", "attrs": ["id": .string(authorID), "text": .string("@\(name)")]], ["type": "text", "text": " "]]
        var paragraphs = document(text)["content"]?.array ?? []
        if paragraphs.isEmpty { paragraphs = [["type": "paragraph", "content": []]] }
        paragraphs[0] = ["type": "paragraph", "content": .array(mention + (paragraphs[0]["content"]?.array ?? []))]
        // Jira refuses empty text nodes: a comment with no text (an image, a card) isn't quoted.
        let quoteBlock: [JSONValue] = excerpt.isEmpty ? []
            : [["type": "blockquote", "content": [["type": "paragraph", "content": [["type": "text", "text": .string(excerpt)]]]]]]
        return ["type": "doc", "version": 1, "content": .array(quoteBlock + paragraphs)]
    }

    /// True when a document is only paragraphs of unformatted text and line breaks: editing it as
    /// plain text and saving it with `document(_:)` loses nothing.
    static func isPlainText(_ node: JSONValue?) -> Bool {
        guard let node else { return true }
        if node.string != nil { return true }
        switch node["type"]?.string {
        case "doc", "paragraph": break
        case "hardBreak": return true
        case "text": return (node["marks"]?.array ?? []).isEmpty
        default: return false
        }
        return (node["content"]?.array ?? []).allSatisfy(isPlainText)
    }

    /// Flattens Atlassian Document Format to plain text.
    static func plainText(_ node: JSONValue?) -> String {
        guard let node else { return "" }
        if let text = node.string { return text }
        var output = ""
        func walk(_ node: JSONValue) {
            switch node["type"]?.string {
            case "text": output += node["text"]?.string ?? ""
            case "hardBreak": output += "\n"
            case "mention": output += node["attrs"]?["text"]?.string ?? ""
            case "listItem": output += "• "
            default: break
            }
            for child in node["content"]?.array ?? [] { walk(child) }
            if ["paragraph", "heading", "listItem", "codeBlock", "blockquote"].contains(node["type"]?.string ?? "") { output += "\n" }
        }
        walk(node)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
