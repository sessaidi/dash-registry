import DashKit
import Foundation
import Testing

/// Meetings in DashQL: the `meetings` dataset and the widget's query.
@MainActor
struct ZoomQueryTests {
    @Test func datasetAndWidgetQuery() async throws {
        let (zoom, host) = makeZoom()
        let standup = MeetingRecord(title: "Backend standup")
        standup.participants = ["Sadik", "Maya"]
        standup.summary = "LAF-12 is blocked on review."
        standup.actionItems = [.init(owner: "Maya", task: "Review LAF-12")]
        standup.endedAt = standup.startedAt.addingTimeInterval(15 * 60)
        let retro = MeetingRecord(title: "Sprint retro")
        retro.participants = ["Sadik"]
        host.context.insert(standup)
        host.context.insert(retro)
        try host.context.save()

        let rows = try await #require(zoom.datasets.first { $0.name == "meetings" }).rows(nil)
        let row = try #require(rows.first { $0["title"] == "Backend standup" })
        #expect(row["tickets"] == ["LAF-12"] && row["owners"] == ["Maya"] && row["minutes"] == 15)

        let mine = try await QueryEngine(datasets: zoom.datasets).run("meetings people:Maya | select title")
        #expect(mine.rows == [["title": "Backend standup"]])

        let query = try #require(try WidgetQuery("title:retro", fields: MeetingWidget.queryFields))
        #expect(await query.apply(to: [standup, retro], row: \.queryRow).map(\.title) == ["Sprint retro"])
    }
}
