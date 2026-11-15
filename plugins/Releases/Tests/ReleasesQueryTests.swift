import DashKit
import Foundation
import Testing

/// Releases in DashQL: rows from the sample timeline, and the widget's query keeping releases.
@MainActor
struct ReleasesQueryTests {
    @Test func rowsQueryAndModelFilter() async throws {
        let timeline = ReleaseSamples.timeline
        let releases = timeline.releases
        #expect(!releases.isEmpty)
        let rows = releases.map { $0.queryRow(repository: timeline.repository.name) }
        #expect(rows.allSatisfy { $0["repo"]?.string == timeline.repository.name && $0["builds"]?.int ?? 0 >= 1 })
        #expect(rows.filter { $0["live"] == true }.count == timeline.trains.count || rows.contains { $0["live"] == true })

        let train = try #require(timeline.trains.last)
        let query = try #require(try WidgetQuery("where train = \"\(train)\"", fields: ReleaseTimelineWidget.queryFields))
        let kept = await query.apply(to: releases) { $0.queryRow(repository: timeline.repository.name) }
        #expect(!kept.isEmpty && kept.allSatisfy { $0.train == train })

        let model = TimelineModel(timelines: [timeline], events: [], train: nil, showEvents: false)
        let filtered = model.keeping(Set(kept.map(\.id)))
        #expect(filtered.releases.map(\.id).sorted() == kept.map(\.id).sorted())

        let builds = releases.flatMap { release in release.builds.map { $0.queryRow(release: release, repository: "api") } }
        let result = try await QueryEngine(datasets: [QueryDataset(name: "builds", summary: "", fields: Build.queryFields) { _ in builds }])
            .run("from builds | count by train")
        #expect(result.rows.reduce(0) { $0 + ($1["count"]?.int ?? 0) } == builds.count)
    }
}
