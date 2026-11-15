import DashKit
import DashKitTesting
import Foundation
import Testing

/// Standups in DashQL: the `standups` and `blockers` datasets.
@MainActor
struct StandupQueryTests {
    @Test func standupsAndBlockers() async throws {
        let standup = DailyStandupFeature(defaults: UserDefaults(suiteName: "standup-query-\(UUID().uuidString)")!)
        let host = try TestHost([standup], models: [StandupDay.self, StandupBlocker.self])
        standup.start(host: host)
        defer { standup.stop() }
        let day = StandupDay(day: "2026-11-13", date: .now.addingTimeInterval(-2 * 86_400), onZoom: true)
        day.update = StandupUpdate(yesterday: [StandupItem(text: "Shipped the fix", ticket: "LAF-12", refs: [])],
                                   today: [StandupItem(text: "Review", ticket: nil, refs: [])], blockers: [])
        let blocked = StandupBlocker(text: "Waiting on CAPIG", owner: "Maya", reference: "LAF-20")
        let fixed = StandupBlocker(text: "QA env down", owner: "Sam")
        fixed.resolvedAt = .now
        [day].forEach(host.context.insert)
        [blocked, fixed].forEach(host.context.insert)
        try host.context.save()

        let engine = QueryEngine(datasets: standup.datasets)
        let standups = try await engine.run("standups on_zoom=true | select day, tickets")
        #expect(standups.rows == [["day": "2026-11-13", "tickets": ["LAF-12"]]])
        let open = try await engine.run("blockers open=true | select owner, ticket")
        #expect(open.rows == [["owner": "Maya", "ticket": "LAF-20"]])
    }
}
