import DashKit
import Foundation
import SwiftData
import Testing

/// Several boards, tickets followed by key, and the old single-board setting.
@MainActor
struct FollowTests {
    nonisolated static func columns(_ name: String) -> String {
        #"{"columnConfig":{"columns":[{"name":"\#(name)","statuses":[{"id":"3"}]}]}}"#
    }

    /// Boards 7 and 8; the JQL search answers by what it asks for.
    static func serve(_ host: String) {
        StubProtocol.serve(host) { request in
            let path = request.url?.path() ?? ""
            let jql = request.httpBody.flatMap { try? JSONValue.parse($0) }?["jql"]?.string ?? ""
            let body: String? = switch path {
            case "/rest/agile/1.0/board/7/configuration": columns("Doing")
            case "/rest/agile/1.0/board/8/configuration": columns("Ops")
            case "/rest/agile/1.0/board/7/issue": issuesPage([issueJSON("WEB-1"), issueJSON("WEB-2")])
            case "/rest/agile/1.0/board/8/issue": issuesPage([issueJSON("OPS-1"), issueJSON("WEB-2")])
            case "/rest/agile/1.0/board": #"{"values":[{"id":7,"name":"Web","type":"scrum","location":{"projectKey":"WEB"}},{"id":8,"name":"Ops","type":"kanban"}]}"#
            case "/rest/api/3/search/jql":
                jql.contains("GONE-1") && jql.hasPrefix("key in") ? nil  // a missing key fails the whole query
                    : jql == "key = GONE-1" ? nil
                    : jql.hasPrefix("key") ? issuesPage([issueJSON("KAN-9")])
                    : issuesPage([])
            default: nil
            }
            return body.map { (200, Data($0.utf8)) } ?? (400, Data(#"{"errorMessages":["no"]}"#.utf8))
        }
    }

    @Test func oldSingleBoardSettingBecomesTheFirstBoard() {
        let (feature, _, _) = makeFeature(host: "old.test", boardID: "7")
        #expect(feature.boards.map(\.id) == [7] && feature.boardID == "7")
    }

    @Test func followsSeveralBoardsAndTicketsByKey() async throws {
        Self.serve("follow.test")
        let (feature, host, _) = makeFeature(host: "follow.test", boardID: "7")
        let found = try await feature.client.boards(matching: "")
        #expect(found.map(\.name) == ["Web", "Ops"] && found[0].project == "WEB")
        await feature.follow(board: found[1])
        await feature.follow("kan-9")
        await feature.follow("GONE-1")
        #expect(feature.lastError == nil)
        #expect(feature.boards.map(\.id) == [7, 8] && feature.columns(board: 8).map(\.name) == ["Ops"])
        #expect(feature.followedKeys == ["KAN-9", "GONE-1"])

        let issues = Dictionary(uniqueKeysWithValues: try host.context.fetch(FetchDescriptor<JiraIssue>()).map { ($0.key, $0) })
        #expect(issues.keys.sorted() == ["KAN-9", "OPS-1", "WEB-1", "WEB-2"])
        #expect(issues["WEB-2"]?.boardIDs == [7, 8] && issues["OPS-1"]?.boardIDs == [8])
        #expect(issues["KAN-9"]?.pinned == true && issues["KAN-9"]?.followed == true && issues["KAN-9"]?.onBoard == false)

        // The widget shows only followed tickets, even in a board's columns.
        let tickets = try host.context.fetch(FetchDescriptor<JiraIssue>()).map(JiraTicket.init)
        let ops = JiraTicket.visible(tickets, config: .init(mode: "board", hideDone: false, board: 8))
        #expect(ops.map(\.key) == ["KAN-9"])

        await feature.unfollow("KAN-9")
        #expect(try host.context.fetch(FetchDescriptor<JiraIssue>()).contains { $0.key == "KAN-9" } == false)
    }
}
