import DashKit
import DashKitTesting
import Foundation
import Testing

/// Meetings, transcripts and the calendar are on the Mac: no Zoom tool makes a request.
@MainActor
struct ZoomOfflineTests {
    @Test func noToolMakesARequest() async throws {
        let (zoom, host) = makeZoom()
        defer { _ = host }
        _ = insertMeeting(host, title: "Daily standup", startedAt: .now.addingTimeInterval(-600), lines: [(5, "Ada", "Today I review KAN-12.")])
        #expect(await NetworkSentinel.requests(running: zoom.tools, values: ["meeting_id": "current", "query": "KAN-12"]) == [])
    }
}
