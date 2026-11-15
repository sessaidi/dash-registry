import DashKit
import Foundation
import Testing

/// Datadog monitors in DashQL: rows, the `monitors` dataset, and the widget's query.
@MainActor
struct DatadogQueryTests {
    @Test func rowsDatasetAndWidgetQuery() async throws {
        let monitors = [
            DatadogMonitor(id: 1, name: "API p99 latency", status: "Alert", type: "metric alert", tags: ["service:api", "env:prod"], lastTriggered: .now),
            DatadogMonitor(id: 2, name: "Checkout errors", status: "Warn", type: "query alert", tags: ["service:checkout", "env:prod"], lastTriggered: nil),
            DatadogMonitor(id: 3, name: "Worker heartbeat", status: "No Data", type: "service check", tags: ["service:worker", "env:qa"], lastTriggered: nil),
        ]
        let row = monitors[0].queryRow(url: URL(string: "https://app.datadoghq.com/monitors/1"))
        #expect(row["service"] == "api" && row["env"] == "prod" && row["severity"] == 0)

        let feature = DatadogMonitorsFeature()
        let dataset = try #require(feature.datasets.first)
        #expect(dataset.name == "monitors" && dataset.fields == DatadogMonitor.queryFields)
        #expect(try await dataset.rows(nil).isEmpty)

        let query = try #require(try WidgetQuery("env:prod -status:Alert", fields: DatadogMonitorsWidget.queryFields))
        #expect(await query.apply(to: monitors) { $0.queryRow(url: nil) }.map(\.id) == [2])
        let worst = try #require(try WidgetQuery("where severity < 2 | sort -severity | take 1", fields: DatadogMonitorsWidget.queryFields))
        #expect(await worst.apply(to: monitors) { $0.queryRow(url: nil) }.map(\.id) == [2])
    }
}
