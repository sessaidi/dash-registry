import DashKit
import Foundation
import Testing

@Suite("Jira parsing")
struct JiraParsingTests {
    @Test func issueFields() throws {
        let issue = JiraClient.Issue(json: try JSONValue.parse(issueJSON("WEB-1", summary: "Fix checkout", statusID: "10002", status: "Code Review")))
        #expect(issue.key == "WEB-1")
        #expect(issue.summary == "Fix checkout")
        #expect(issue.statusID == "10002" && issue.statusName == "Code Review" && issue.statusCategory == "indeterminate")
        #expect(issue.assignee == "Maya Chen" && issue.priority == "High" && issue.issueType == "Story")
        #expect(issue.labels == ["web", "q2"])
        // Jira's "+0000" offset without a colon.
        #expect(issue.updated == Date(timeIntervalSince1970: 1_772_619_630))
    }

    @Test func missingFieldsDefault() throws {
        let issue = JiraClient.Issue(json: try JSONValue.parse(#"{"key":"WEB-2","fields":{"assignee":null}}"#))
        #expect(issue.key == "WEB-2" && issue.summary == "" && issue.statusName == "")
        #expect(issue.assignee == nil && issue.priority == nil && issue.updated == nil && issue.labels.isEmpty)
    }

    @Test func plainTextFlattensADF() throws {
        let doc = try JSONValue.parse("""
            {"type":"doc","version":1,"content":[
              {"type":"heading","content":[{"type":"text","text":"Steps"}]},
              {"type":"paragraph","content":[{"type":"text","text":"Ping "},{"type":"mention","attrs":{"text":"@Sam"}},
                {"type":"hardBreak"},{"type":"text","text":"then retry."}]},
              {"type":"bulletList","content":[{"type":"listItem","content":[{"type":"paragraph","content":[{"type":"text","text":"one"}]}]}]}
            ]}
            """)
        #expect(JiraClient.plainText(doc) == "Steps\nPing @Sam\nthen retry.\n• one")
        #expect(JiraClient.plainText(.string("plain")) == "plain")
        #expect(JiraClient.plainText(nil) == "")
    }
}

@MainActor
@Suite("Jira client")
struct JiraClientTests {
    static func client(_ host: String) -> JiraClient {
        JiraClient(connection: FakeAtlassian(host: host).connection!)
    }

    @Test func searchFollowsPageTokens() async throws {
        StubProtocol.serve("search.test") { request in
            let token = request.jsonBody?["nextPageToken"]?.string
            let page = token == nil
                ? issuesPage([issueJSON("A-1"), issueJSON("A-2")], next: "p2")
                : issuesPage([issueJSON("A-3")])
            return (200, Data(page.utf8))
        }
        let issues = try await Self.client("search.test").search("project = A")
        #expect(issues.map(\.key) == ["A-1", "A-2", "A-3"])

        let requests = StubProtocol.requests("search.test")
        #expect(requests.count == 2)
        let first = try #require(requests.first)
        #expect(first.httpMethod == "POST" && first.url?.path() == "/rest/api/3/search/jql")
        #expect(first.value(forHTTPHeaderField: "Authorization") == "Basic dGVzdEBleGFtcGxlLmNvbTp0b2tlbg==")
        #expect(first.jsonBody?["jql"] == "project = A")
        #expect(first.jsonBody?["maxResults"] == 100)
        #expect(first.jsonBody?["fields"]?.array?.count == JiraClient.issueFields.count)
        #expect(requests.last?.jsonBody?["nextPageToken"] == "p2")
    }

    @Test func searchStopsAtLimit() async throws {
        StubProtocol.serve("limit.test") { _ in (200, Data(issuesPage([issueJSON("A-1"), issueJSON("A-2")], next: "more").utf8)) }
        let issues = try await Self.client("limit.test").search("x", limit: 3)
        #expect(issues.count == 4)
        #expect(StubProtocol.requests("limit.test").count == 2)
    }

    @Test func boardColumns() async throws {
        StubProtocol.serve("columns.test", routes: [
            "GET /rest/agile/1.0/board/7/configuration": """
                {"columnConfig":{"columns":[{"name":"To Do","statuses":[{"id":"1"}]},{"name":"Doing","statuses":[{"id":"3"},{"id":"10002"}]}]}}
                """,
        ])
        let columns = try await Self.client("columns.test").boardColumns(7)
        #expect(columns == [JiraClient.Column(name: "To Do", statusIDs: ["1"]), JiraClient.Column(name: "Doing", statusIDs: ["3", "10002"])])
    }

    @Test func boardIssuesFromActiveSprints() async throws {
        StubProtocol.serve("scrum.test", routes: [
            "GET /rest/agile/1.0/board/7/sprint": #"{"values":[{"id":41},{"id":42}]}"#,
            "GET /rest/agile/1.0/board/7/sprint/41/issue": issuesPage([issueJSON("S-1")]),
            "GET /rest/agile/1.0/board/7/sprint/42/issue": issuesPage([issueJSON("S-2")]),
        ])
        let issues = try await Self.client("scrum.test").boardIssues(7)
        #expect(issues.map(\.key) == ["S-1", "S-2"])
        let sprint = try #require(StubProtocol.requests("scrum.test").first)
        #expect(sprint.query("state") == "active")
        #expect(StubProtocol.requests("scrum.test").last?.query("fields") == JiraClient.issueFields.joined(separator: ","))
    }

    @Test func boardIssuesFallsBackToKanban() async throws {
        // Kanban boards reject the sprint endpoint; the board's open/recent issues are used instead.
        StubProtocol.serve("kanban.test", routes: [
            "GET /rest/agile/1.0/board/9/issue": issuesPage([issueJSON("K-1"), issueJSON("K-2")]),
        ])
        let issues = try await Self.client("kanban.test").boardIssues(9)
        #expect(issues.map(\.key) == ["K-1", "K-2"])
        let request = try #require(StubProtocol.requests("kanban.test").last)
        #expect(request.query("jql") == "statusCategory != Done OR resolved >= -14d")
        #expect(request.query("maxResults") == "200")
    }

    @Test func issueDetail() async throws {
        let comments = (1...20).map { #"{"author":{"displayName":"User \#($0)"},"created":"2026-03-0\#($0 % 9 + 1)","body":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"c\#($0)"}]}]}}"# }
        StubProtocol.serve("detail.test", routes: [
            "GET /rest/api/3/issue/WEB-9": """
                {"key":"WEB-9","fields":{"summary":"Broken","status":{"id":"1","name":"To Do","statusCategory":{"key":"new"}},
                 "priority":{"name":"Low"},"issuetype":{"name":"Bug"},"reporter":{"displayName":"Leo"},"parent":{"key":"WEB-1"},"labels":["x"],
                 "description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"It fails."}]}]},
                 "comment":{"comments":[\(comments.joined(separator: ","))]}}}
                """,
        ])
        let detail = try await Self.client("detail.test").issueDetail("WEB-9")
        #expect(detail["summary"] == "Broken" && detail["status"] == "To Do" && detail["type"] == "Bug" && detail["priority"] == "Low")
        #expect(detail["assignee"] == "Unassigned" && detail["reporter"] == "Leo" && detail["parent"] == "WEB-1")
        #expect(detail["labels"] == ["x"])
        #expect(detail["url"] == "https://detail.test/browse/WEB-9")
        #expect(detail["description"] == "It fails.")
        let kept = try #require(detail["comments"]?.array)
        #expect(kept.count == 15)
        #expect(kept.first?["author"] == "User 6" && kept.last?["body"] == "c20")
        let request = try #require(StubProtocol.requests("detail.test").first)
        #expect(request.query("fields")?.hasSuffix(",description,comment") == true)
    }

    @Test func transitionsAndComment() async throws {
        StubProtocol.serve("write.test", routes: [
            "GET /rest/api/3/issue/WEB-3/transitions": #"{"transitions":[{"id":"11","name":"Start"},{"id":"21","name":"Code Review"},{"name":"broken"}]}"#,
            "POST /rest/api/3/issue/WEB-3/transitions": "",
            "POST /rest/api/3/issue/WEB-3/comment": #"{"id":"100"}"#,
        ])
        let client = Self.client("write.test")
        let transitions = try await client.transitions("WEB-3")
        #expect(transitions.map(\.id) == ["11", "21"] && transitions.map(\.name) == ["Start", "Code Review"])

        try await client.transition("WEB-3", to: "21")
        try await client.comment("WEB-3", text: "First.\n\nSecond.")
        let requests = StubProtocol.requests("write.test")
        #expect(requests[1].jsonBody == ["transition": ["id": "21"]])
        #expect(requests[2].jsonBody == [
            "body": ["type": "doc", "version": 1, "content": [
                ["type": "paragraph", "content": [["type": "text", "text": "First."]]],
                ["type": "paragraph", "content": [["type": "text", "text": "Second."]]],
            ]],
        ])
    }

    @Test func errorsSurfaceJiraMessages() async throws {
        StubProtocol.serve("error.test") { _ in (400, Data(#"{"errorMessages":["The value 'NOPE' does not exist for the field 'project'."]}"#.utf8)) }
        await #expect(throws: HTTPError.self) { try await Self.client("error.test").search("project = NOPE") }
        do {
            _ = try await Self.client("error.test").search("project = NOPE")
        } catch {
            #expect(error.localizedDescription == "Jira error 400: The value 'NOPE' does not exist for the field 'project'.")
        }
    }
}
