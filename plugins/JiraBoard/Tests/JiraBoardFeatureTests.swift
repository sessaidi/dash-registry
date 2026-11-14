import DashKit
import DashKitUI
import Foundation
import SwiftData
import Testing

@MainActor
@Suite("Jira Board feature")
struct JiraBoardFeatureTests {
    static let columns = #"{"columnConfig":{"columns":[{"name":"To Do","statuses":[{"id":"1"}]},{"name":"In Progress","statuses":[{"id":"3"}]}]}}"#

    /// Board 7 (kanban) holds `board`; the follow JQL matches `followed`.
    static func serve(_ host: String, board: [String], followed: [String]) {
        StubProtocol.serve(host, routes: [
            "GET /rest/agile/1.0/board/7/configuration": columns,
            "GET /rest/agile/1.0/board/7/issue": issuesPage(board),
            "POST /rest/api/3/search/jql": issuesPage(followed),
        ])
    }

    static func stored(_ host: FakeHost) throws -> [String: JiraIssue] {
        Dictionary(uniqueKeysWithValues: try host.context.fetch(FetchDescriptor<JiraIssue>()).map { ($0.key, $0) })
    }

    func tool(_ feature: JiraBoardFeature, _ name: String) throws -> ClaudeTool {
        try #require(feature.tools.first { $0.name == name })
    }

    @Test func identityMatchesBuiltIn() {
        let feature = JiraBoardFeature(defaults: UserDefaults(suiteName: "jira-board-tests-\(UUID().uuidString)")!)
        #expect(feature.id == "jira-board" && feature.storagePrefix == "jira-board")
        #expect(feature.requires == ["atlassian"] && feature.layer == .feature)
        #expect(feature.widgets.map(\.kind) == ["jira.board"])
        #expect(feature.widgets.first?.sizeLimits == GridLimits(minW: 4, minH: 6, maxW: 12, maxH: 24))
        #expect(feature.widgets.first?.preview != nil)
        #expect(feature.tools.map(\.name) == ["jira_list_issues", "jira_follow", "jira_get_issue", "jira_search", "jira_add_comment", "jira_transition_issue"])
        #expect(feature.tools.filter(\.requiresApproval).map(\.name) == ["jira_add_comment", "jira_transition_issue"])
        #expect(feature.followJQL == JiraBoardFeature.defaultJQL && feature.pollMinutes == 5)
    }

    @Test func preferencesUseBuiltInKeys() throws {
        let defaults = try #require(UserDefaults(suiteName: "jira-board-tests-\(UUID().uuidString)"))
        defaults.set("12", forKey: "jira-board.boardID")
        defaults.set(15, forKey: "jira-board.poll")
        defaults.set(try JSONEncoder().encode([JiraClient.Column(name: "Doing", statusIDs: ["3"])]), forKey: "jira-board.columns")
        let feature = JiraBoardFeature(defaults: defaults)
        #expect(feature.boardID == "12" && feature.pollMinutes == 15 && feature.columns.map(\.name) == ["Doing"])
        feature.followJQL = "project = WEB"
        #expect(defaults.string(forKey: "jira-board.jql") == "project = WEB")
    }

    @Test func syncStoresBoardAndFollowed() async throws {
        Self.serve("sync.test", board: [issueJSON("WEB-1", statusID: "1", status: "To Do", category: "new"), issueJSON("WEB-2")],
                   followed: [issueJSON("WEB-2"), issueJSON("OPS-9")])
        let (feature, host, _) = makeFeature(host: "sync.test", boardID: "7", followJQL: "assignee = currentUser()")
        await feature.sync()

        #expect(feature.lastError == nil && feature.lastSync != nil)
        #expect(feature.columns.map(\.name) == ["To Do", "In Progress"])
        let issues = try Self.stored(host)
        #expect(issues.keys.sorted() == ["OPS-9", "WEB-1", "WEB-2"])
        #expect(issues["WEB-1"]?.onBoard == true && issues["WEB-1"]?.followed == false)
        #expect(issues["WEB-2"]?.onBoard == true && issues["WEB-2"]?.followed == true)
        #expect(issues["OPS-9"]?.onBoard == false && issues["OPS-9"]?.followed == true)
        #expect(issues["WEB-1"]?.url == "https://sync.test/browse/WEB-1")
        // As in the built-in feature, an issue both on the board and followed is announced once per list.
        #expect(host.activity.events.filter { $0.kind == "issue.appeared" }.map(\.title).sorted() == [
            "OPS-9 on your board: Summary", "WEB-1 on your board: Summary", "WEB-2 on your board: Summary", "WEB-2 on your board: Summary",
        ])
        #expect(host.activity.events.allSatisfy { $0.source == "jira-board" })
    }

    @Test func resyncEmitsMovesAndDropsStale() async throws {
        Self.serve("resync.test", board: [issueJSON("WEB-1"), issueJSON("WEB-2")], followed: [issueJSON("WEB-2")])
        let (feature, host, _) = makeFeature(host: "resync.test", boardID: "7", followJQL: "x")
        await feature.sync()

        Self.serve("resync.test", board: [issueJSON("WEB-2", statusID: "10002", status: "Code Review")],
                   followed: [issueJSON("WEB-2", statusID: "10002", status: "Code Review")])
        await feature.sync()

        let issues = try Self.stored(host)
        #expect(issues.keys.sorted() == ["WEB-2"])
        #expect(issues["WEB-2"]?.statusName == "Code Review" && issues["WEB-2"]?.statusID == "10002")
        let moved = try #require(host.activity.events.first { $0.kind == "issue.status_changed" })
        #expect(moved.title == "WEB-2 moved to Code Review")
        #expect(moved.importance == .notable)
        #expect(moved.link == "https://resync.test/browse/WEB-2")
    }

    @Test func syncRecordsErrors() async throws {
        StubProtocol.serve("broken.test") { _ in (401, Data(#"{"message":"Unauthorized"}"#.utf8)) }
        let (feature, host, _) = makeFeature(host: "broken.test", boardID: "7")
        await feature.sync()
        #expect(feature.lastError == "Jira rejected the credentials (401). Check the token in Settings.")
        await #expect(throws: ToolError.self) { try await feature.prepare(host: host) }
    }

    @Test func toolsNeedAtlassian() async throws {
        let (feature, host, atlassian) = makeFeature(host: "offline.test")
        atlassian.connected = false
        await #expect(throws: ToolError("Connect Atlassian in Settings › Integrations.")) {
            _ = try await tool(feature, "jira_search").run(["jql": "x"])
        }
        host.extensions = [feature]
        await #expect(throws: ToolError("The Atlassian integration is not installed.")) {
            _ = try await tool(feature, "jira_get_issue").run(["key": "WEB-1"])
        }
        #expect(StubProtocol.requests("offline.test").isEmpty)
    }

    @Test func listIssuesFiltersCache() async throws {
        Self.serve("list.test", board: [issueJSON("WEB-1", statusID: "1", status: "To Do", category: "new"), issueJSON("WEB-2")],
                   followed: [issueJSON("OPS-9", status: "in progress")])
        let (feature, host, _) = makeFeature(host: "list.test", boardID: "7", followJQL: "x")
        defer { withExtendedLifetime(host) {} }
        await feature.sync()
        let list = try tool(feature, "jira_list_issues")

        let all = try await list.run([:])
        #expect(all.array?.count == 3)
        let board = try await list.run(["scope": "board"])
        #expect(Set(board.array?.compactMap { $0["key"]?.string } ?? []) == ["WEB-1", "WEB-2"])
        let followed = try await list.run(["scope": "followed"])
        #expect(followed.array?.map { $0["key"] } == ["OPS-9"])
        #expect(followed.array?.first?["followed"] == true && followed.array?.first?["onBoard"] == false)
        let inProgress = try await list.run(["status": "In Progress"])
        #expect(Set(inProgress.array?.compactMap { $0["key"]?.string } ?? []) == ["WEB-2", "OPS-9"])
        let first = try #require(all.array?.first { $0["key"] == "WEB-1" })
        #expect(first["assignee"] == "Maya Chen" && first["priority"] == "High" && first["type"] == "Story" && first["statusCategory"] == "new")
    }

    @Test func searchAndGetTools() async throws {
        StubProtocol.serve("live.test", routes: [
            "POST /rest/api/3/search/jql": issuesPage([issueJSON("WEB-5", summary: "Search hit", assignee: nil)]),
            "GET /rest/api/3/issue/WEB-5": issueJSON("WEB-5", summary: "Search hit"),
        ])
        let (feature, host, _) = makeFeature(host: "live.test")
        defer { withExtendedLifetime(host) {} }
        let results = try await tool(feature, "jira_search").run(["jql": "text ~ hit"])
        #expect(results == [["key": "WEB-5", "summary": "Search hit", "status": "In Progress", "assignee": "Unassigned"]])
        #expect(StubProtocol.requests("live.test").first?.jsonBody?["jql"] == "text ~ hit")

        // Keys are upper-cased before the request.
        let detail = try await tool(feature, "jira_get_issue").run(["key": "web-5"])
        #expect(detail["key"] == "WEB-5" && detail["summary"] == "Search hit")

        await #expect(throws: ToolError.self) { _ = try await tool(feature, "jira_search").run([:]) }
    }

    @Test func commentTool() async throws {
        StubProtocol.serve("comment.test", routes: ["POST /rest/api/3/issue/WEB-4/comment": #"{"id":"1"}"#])
        let (feature, host, _) = makeFeature(host: "comment.test")
        defer { withExtendedLifetime(host) {} }
        let result = try await tool(feature, "jira_add_comment").run(["key": "WEB-4", "text": "Looks good."])
        #expect(result == "commented")
        #expect(StubProtocol.requests("comment.test").first?.jsonBody?["body"]?["content"]?[0]?["content"]?[0]?["text"] == "Looks good.")
    }

    @Test func transitionToolMatchesByName() async throws {
        StubProtocol.serve("move.test", routes: [
            "GET /rest/api/3/issue/WEB-4/transitions": #"{"transitions":[{"id":"11","name":"Start Progress"},{"id":"21","name":"Code Review"}]}"#,
            "POST /rest/api/3/issue/WEB-4/transitions": "",
        ])
        let (feature, host, _) = makeFeature(host: "move.test")
        defer { withExtendedLifetime(host) {} }
        let move = try tool(feature, "jira_transition_issue")

        // Exact (case-insensitive) first, then a contained match.
        #expect(try await move.run(["key": "WEB-4", "status": "code review"]) == "Moved via \"Code Review\".")
        #expect(try await move.run(["key": "WEB-4", "status": "progress"]) == "Moved via \"Start Progress\".")
        let posts = StubProtocol.requests("move.test").filter { $0.httpMethod == "POST" }
        #expect(posts.map { $0.jsonBody?["transition"]?["id"] } == ["21", "11"])

        await #expect(throws: ToolError("No transition named \"Done\" for WEB-4. Available: Start Progress, Code Review.")) {
            _ = try await move.run(["key": "WEB-4", "status": "Done"])
        }
    }

    @Test func widgetSnapshotAndPreviewSamples() async throws {
        Self.serve("widget.test", board: [issueJSON("WEB-1")], followed: [issueJSON("OPS-2")])
        let (feature, host, _) = makeFeature(host: "widget.test", boardID: "7", followJQL: "x")
        await feature.sync()
        let context = WidgetContext(widgetID: UUID(), host: host)
        let board = await JiraBoardWidget.snapshot(config: JiraBoardWidget.Config(mode: "board", hideDone: false), context: context)
        #expect(board.array?.map { $0["key"] } == ["WEB-1"])
        let followed = await JiraBoardWidget.snapshot(config: JiraBoardWidget.Config(mode: "followed", hideDone: false), context: context)
        #expect(followed.array?.map { $0["key"] } == ["OPS-2"])

        // Previews draw from samples that fill every sample column, and hideDone drops done tickets.
        let samples = JiraTicket.samples
        let onBoard = JiraTicket.visible(samples, config: JiraBoardWidget.defaultConfig)
        #expect(JiraClient.Column.samples.allSatisfy { column in onBoard.contains { column.statusIDs.contains($0.statusID) } })
        let open = JiraTicket.visible(samples, config: JiraBoardWidget.Config(mode: "board", hideDone: true))
        #expect(open.count == onBoard.count - 1 && open.allSatisfy { $0.statusCategory != "done" })
        #expect(!JiraTicket.visible(samples, config: JiraBoardWidget.Config(mode: "followed", hideDone: false)).isEmpty)
    }
}
