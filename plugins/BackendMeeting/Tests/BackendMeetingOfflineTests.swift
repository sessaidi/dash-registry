import DashKit
import DashKitTesting
import Foundation
import Testing

/// Dashii reads the reports already written; building one (GitHub, Jira) is the user's.
@MainActor
struct BackendMeetingOfflineTests {
    @Test func noToolMakesARequest() async throws {
        let feature = BackendMeetingFeature(defaults: UserDefaults(suiteName: "backend-meeting-\(UUID().uuidString)")!)
        feature.outputFolder = FileManager.default.temporaryDirectory.appending(path: "backend-meeting-\(UUID().uuidString)").path
        let items: [any DashExtension] = [
            TestIntegration(id: "atlassian", baseURL: URL(string: "https://atl-sentinel.test")!),
            TestIntegration(id: "github", baseURL: URL(string: "https://gh-sentinel.test")!, exports: ["login": "me"]), feature,
        ]
        let host = try TestHost(items)
        defer { _ = host }
        host.start(items)
        #expect(await NetworkSentinel.requests(running: feature.tools) == [])
    }
}
