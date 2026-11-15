import DashKit
import DashKitTesting
import Foundation
import Testing

/// Backend Meeting reports in DashQL: the `reports` dataset.
@MainActor
struct BackendMeetingQueryTests {
    @Test func reportsDataset() async throws {
        let feature = BackendMeetingFeature(defaults: UserDefaults(suiteName: "backend-meeting-query-\(UUID().uuidString)")!)
        let host = try TestHost([feature])
        host.start([feature])
        let report = BackendReport(start: .now.addingTimeInterval(-14 * 86_400), end: .now, cycleWeeks: 2,
                                   markdown: "- **Social connection**: Apple sign-in\n- **In chantier**:\n  - DVR cap\n- **Debug & Fix**")
        host.context.insert(report)
        try host.context.save()
        let result = try await QueryEngine(datasets: feature.datasets).run("from reports | select weeks, themes")
        #expect(result.rows == [["weeks": 2, "themes": ["Social connection", "In chantier", "Debug & Fix"]]])
    }
}
