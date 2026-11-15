import DashKit
import DashKitTesting
import Foundation
import SwiftUI
import Testing

@MainActor
struct AcmeBoardFeatureTests {
    static let tickets = """
        [{"id":"ACME-1","title":"Checkout down","status":"doing","priority":"urgent","assignee":"Ada"},
         {"id":"ACME-2","title":"Dark mode","status":"todo","priority":"normal"},
         {"id":"ACME-3","title":"Old bug","status":"done","priority":"high","assignee":"Sam"}]
        """

    /// A feature on a stand-in `acme` integration whose requests get canned answers, with its
    /// own preferences (so tests don't share what was announced).
    func make(tickets: String = tickets, defaults: UserDefaults? = nil) throws -> (AcmeBoardFeature, TestHost, String) {
        let host = "acme-\(UUID().uuidString.prefix(8)).test"
        StubHTTP.serve(host, routes: ["/tickets": tickets])
        let acme = TestIntegration(id: "acme", baseURL: URL(string: "https://\(host)")!)
        let feature = AcmeBoardFeature(defaults: defaults ?? Self.freshDefaults())
        let dash = try TestHost([acme, feature])
        dash.start([acme, feature])
        return (feature, dash, host)
    }

    static func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "acme-board-tests-\(UUID().uuidString)")!
    }

    @Test func refreshReadsThroughTheIntegrationAndFlagsUrgentTickets() async throws {
        let (feature, dash, _) = try make()
        defer { feature.stop() }
        await feature.refresh()
        #expect(feature.tickets.map(\.id) == ["ACME-1", "ACME-2", "ACME-3"])
        #expect(dash.activity.events.filter { $0.kind == "acme.urgent" }.count == 1)
        // The same urgent ticket again isn't news.
        await feature.refresh()
        #expect(dash.activity.events.filter { $0.kind == "acme.urgent" }.count == 1)
        #expect(try await dash.runTool("acme_board_tickets")?.array?.count == 3)
    }

    @Test func aRelaunchDoesNotAnnounceTheSameTicketAgain() async throws {
        let defaults = Self.freshDefaults()
        let (first, firstDash, _) = try make(defaults: defaults)
        await first.refresh()
        #expect(firstDash.activity.events.filter { $0.kind == "acme.urgent" }.count == 1)
        first.stop()
        let (second, dash, _) = try make(defaults: defaults)
        defer { second.stop() }
        await second.refresh()
        #expect(dash.activity.events.filter { $0.kind == "acme.urgent" }.isEmpty)
    }

    @Test func summariesGoToASmallerModel() async throws {
        let (feature, dash, _) = try make()
        defer { feature.stop() }
        await feature.refresh()
        dash.testDashii.reply = #"{"summary":"Checkout is down."}"#
        #expect(try await dash.runTool("acme_board_summarize") == "Checkout is down.")
        let call = try #require(dash.testDashii.calls.last)
        #expect(call.prompt.contains("Checkout down") && !call.prompt.contains("Old bug"))
    }

    @Test func widgetHidesDoneAndPutsUrgentFirst() async throws {
        let (feature, dash, _) = try make()
        defer { feature.stop() }
        await feature.refresh()
        let loader = WidgetSnapshotLoader(provider: TicketsProvider(host: dash))
        await loader.load(.init())
        #expect(loader.snapshot?.tickets.map(\.id) == ["ACME-1", "ACME-2"])
        await loader.load(.init(showDone: true))
        #expect(loader.snapshot?.tickets.count == 3)
        #expect(WidgetType(TicketsWidget.self).preview != nil)
    }

    @Test func triageSkipsWhenNothingNeedsIt() async throws {
        let (feature, dash, _) = try make()
        defer { feature.stop() }
        #expect(await AcmeAgents.triage.precheck?(dash) == .skip("No urgent or high ticket."))
        await feature.refresh()
        guard case .run(let context) = await AcmeAgents.triage.precheck?(dash) else { Issue.record("expected a run"); return }
        #expect(context.contains("ACME-1") && !context.contains("ACME-3"))
        #expect(AcmeAgents.triage.allows(tool: "acme_board_tickets", from: "acme-board", requiresApproval: false))
        #expect(!AcmeAgents.triage.allows(tool: "acme_get", from: "acme", requiresApproval: false))
        #expect(feature.agents.map(\.id) == ["triage"])
    }

    @Test func triageRunsForHighTicketsToo() async throws {
        let (feature, dash, _) = try make(tickets: #"[{"id":"ACME-7","title":"Slow search","status":"todo","priority":"high"}]"#)
        defer { feature.stop() }
        await feature.refresh()
        guard case .run(let context) = await AcmeAgents.triage.precheck?(dash) else { Issue.record("expected a run"); return }
        #expect(context.contains("ACME-7"))
    }

    @Test func reportsParseIntoFindings() throws {
        let report = try AgentReport.parse(#"{"summary":"ACME-1 first.","findings":[{"severity":"critical","title":"Checkout down","detail":"urgent, doing","target":"ACME-1","suggestion":"Page Ada"}]}"#,
                                           agentID: "acme-board.triage", startedAt: .now, reason: "manual")
        #expect(report.status == .findings && report.severity == .critical)
    }

    @Test func statementsMapToTools() {
        let feature = AcmeBoardFeature(defaults: Self.freshDefaults())
        #expect(Set(feature.verbs.map(\.tool)).isSubset(of: Set(feature.tools.map(\.name))))
    }
}
