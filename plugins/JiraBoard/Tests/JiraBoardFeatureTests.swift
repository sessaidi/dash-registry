import DashKit
import DashKitTesting
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

    func tool(_ feature: JiraBoardFeature, _ name: String) throws -> DashiiTool {
        try #require(feature.tools.first { $0.name == name })
    }

    @Test func identityMatchesBuiltIn() {
        let feature = JiraBoardFeature(defaults: UserDefaults(suiteName: "jira-board-tests-\(UUID().uuidString)")!)
        #expect(feature.id == "jira-board" && feature.storagePrefix == "jira-board")
        #expect(feature.metadata.version == "1.15.0" && feature.metadata.minimumDashKit == "2.0.0")
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

    @Test func readersNeedAnAtlassianThatFetchesThenReads() async throws {
        let (feature, host, atlassian) = makeFeature(host: "offline.test")
        // Offline is fine: the readers only read what Dash stored.
        atlassian.connected = false
        #expect(try await tool(feature, "jira_search").run(["jql": "x"])["fetched"] == false)
        // An older Atlassian plugin would read Jira live: refused.
        atlassian.fetchesThenReads = false
        await #expect(throws: ToolError("Update the Atlassian plugin (1.7 or later) to read Jira issues from Dash.")) {
            _ = try await tool(feature, "jira_get_issue").run(["key": "WEB-1"])
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

    @Test func searchAndGetReadThroughAtlassian() async throws {
        let (feature, host, atlassian) = makeFeature(host: "read.test")
        defer { withExtendedLifetime(host) {} }
        atlassian.stored = [
            "jira_jql_search": ["items": [["key": "WEB-5", "summary": "Search hit"]], "stale": false, "synced_at": "2026-11-17T10:00:00Z"],
            "jira_issue": ["key": "WEB-5", "summary": "Search hit", "stale": true, "synced_at": "2026-11-17T09:00:00Z"],
        ]
        let results = try await tool(feature, "jira_search").run(["jql": "text ~ hit"])
        #expect(results["items"]?[0]?["key"] == "WEB-5" && results["stale"] == false)
        // Keys are upper-cased; searches keep the old limit of 50.
        let detail = try await tool(feature, "jira_get_issue").run(["key": "web-5"])
        #expect(detail["summary"] == "Search hit" && detail["stale"] == true)
        #expect(atlassian.reads.map(\.reader) == ["jira_jql_search", "jira_issue"])
        #expect(atlassian.reads.map(\.input) == [["jql": "text ~ hit", "limit": 50], ["key": "WEB-5"]])
        #expect(StubProtocol.requests("read.test").isEmpty)

        await #expect(throws: ToolError.self) { _ = try await tool(feature, "jira_search").run([:]) }
    }

    @Test func followAnswersAtOnceAndSyncsInTheBackground() async throws {
        Self.serve("follow-tool.test", board: [], followed: [issueJSON("KAN-9")])
        let (feature, host, _) = makeFeature(host: "follow-tool.test")
        defer { withExtendedLifetime(host) {} }
        #expect(try await tool(feature, "jira_follow").run(["key": "kan-9"]) == ["key": "KAN-9", "following": true])
        #expect(feature.followedKeys == ["KAN-9"])
        #expect(try await tool(feature, "jira_follow").run(["key": "KAN-9", "follow": false]) == ["key": "KAN-9", "following": false])
        await #expect(throws: ToolError.self) { _ = try await tool(feature, "jira_follow").run(["key": "nope"]) }
    }

    // MARK: No network for Dashii and agents

    @Test func noToolDashiiGetsCallsJira() async throws {
        Self.serve("sentinel.test", board: [issueJSON("WEB-1")], followed: [])
        let (feature, host, atlassian) = makeFeature(host: "sentinel.test", boardID: "7")
        defer { withExtendedLifetime(host) {} }
        await feature.sync()
        atlassian.stored = ["jira_issue": ["key": "WEB-1", "stale": false]]
        let values: [String: JSONValue] = ["key": "WEB-1", "jql": "project = WEB"]
        #expect(await NetworkSentinel.requests(running: feature.tools, values: values) == [])
        // Commenting and moving tickets are the user's: Dashii and agents never get them.
        let remote = feature.tools.filter { !$0.isForDashii }
        #expect(remote.map(\.name) == ["jira_add_comment", "jira_transition_issue"] && remote.allSatisfy { $0.writesRemotely && $0.requiresApproval })
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

    @Test func dashiiSearchesFiltersAndOpensIssues() throws {
        #expect(JiraBoardWidget.actions.map(\.name) == ["search", "filter_status", "set_mode", "set_board", "hide_done", "select_issue", "clear_selection", "clear"])
        // Actions that would change settings say they're temporary; the view applies them on a copy.
        #expect(JiraBoardWidget.actions.filter { ["set_mode", "set_board", "hide_done"].contains($0.name) }.allSatisfy { $0.description.contains("Temporary") })
        let tickets = JiraTicket.samples
        let columns = JiraClient.Column.samples
        let boards = [(id: 7, name: "Web"), (id: 9, name: "Ops board")]
        var config = JiraBoardWidget.defaultConfig
        var search = ""
        var status = ""
        func run(_ name: String, _ input: JSONValue) throws -> JiraBoardActions.Outcome {
            try JiraBoardActions.perform(name, input, config: &config, search: &search, status: &status, tickets: tickets, boards: boards, columns: columns)
        }
        _ = try run("search", ["text": "maya"])
        #expect(JiraBoardActions.filter(tickets, search: search, status: status, columns: columns).map(\.key) == ["WEB-482", "WEB-466", "OPS-212"])
        _ = try run("filter_status", ["status": "review"])
        #expect(JiraBoardActions.filter(tickets, search: search, status: status, columns: columns).map(\.key) == ["WEB-466"])
        #expect(throws: ToolError.self) { try run("filter_status", ["status": "Blocked"]) }
        _ = try run("set_board", ["board": "ops"])
        #expect(config.board == 9 && config.mode == "board")
        _ = try run("set_mode", ["mode": "followed"])
        _ = try run("hide_done", ["on": true])
        #expect(config.mode == "followed" && config.hideDone)
        #expect(try run("select_issue", ["key": "web-475"]).select?.key == "WEB-475")
        #expect(throws: ToolError.self) { try run("select_issue", ["key": "NOPE-1"]) }
        _ = try run("clear", [:])
        #expect(search.isEmpty && status.isEmpty)
    }

    @Test func widgetSnapshotAndPreviewSamples() async throws {
        Self.serve("widget.test", board: [issueJSON("WEB-1")], followed: [issueJSON("OPS-2")])
        let (feature, host, _) = makeFeature(host: "widget.test", boardID: "7", followJQL: "x")
        await feature.sync()
        let context = WidgetContext(widgetID: UUID(), host: host)
        let board = await JiraBoardWidget.snapshot(config: JiraBoardWidget.Config(mode: "board", hideDone: false), context: context)
        #expect(board["issues"]?.array?.map { $0["key"] } == ["OPS-2"])
        #expect(board["mode"] == "board" && board["explanation"]?.string?.contains("status_category") == true)
        let followed = await JiraBoardWidget.snapshot(config: JiraBoardWidget.Config(mode: "followed", hideDone: false), context: context)
        #expect(followed["issues"]?.array?.map { $0["key"] } == ["OPS-2"])

        // Previews draw from samples that fill every sample column, and hideDone drops done tickets.
        let samples = JiraTicket.samples
        let onBoard = JiraTicket.visible(samples, config: JiraBoardWidget.Config(mode: "board", hideDone: false))
        #expect(JiraClient.Column.samples.allSatisfy { column in onBoard.contains { column.statusIDs.contains($0.statusID) } })
        let open = JiraTicket.visible(samples, config: JiraBoardWidget.Config(mode: "board", hideDone: true))
        #expect(open.count == onBoard.count - 1 && open.allSatisfy { $0.statusCategory != "done" })
        #expect(!JiraTicket.visible(samples, config: JiraBoardWidget.Config(mode: "followed", hideDone: false)).isEmpty)
    }
}

/// Followed tickets are let go once done and merged.
struct JiraAutoUnfollowTests {
    @Test func finishedMeansNoOpenPullRequest() {
        #expect(JiraBoardFeature.isFinished((count: 0, state: nil)))
        #expect(JiraBoardFeature.isFinished((count: 2, state: "MERGED")))
        #expect(JiraBoardFeature.isFinished((count: 1, state: "DECLINED")))
        #expect(!JiraBoardFeature.isFinished((count: 1, state: "OPEN")))
    }
}
