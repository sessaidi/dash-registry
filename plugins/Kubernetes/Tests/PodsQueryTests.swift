import DashKit
import Foundation
import Testing

/// Pods in DashQL: the `pods` dataset and the widget's query.
@MainActor
@Suite(.serialized)
struct PodsQueryTests {
    @Test func datasetRowsAndWidgetQuery() async throws {
        let k8s = try makeIntegration(singleContext(host: "query.test", user: ["token: t"], namespace: "team-q"))
        let pods = PodsFeature()
        let host = FakeHost([k8s, pods])
        StubProtocol.serve("query.test", json: PodsFeatureTests.list([("web", "running"), ("worker", "CrashLoopBackOff")]))
        k8s.start(host: host)
        pods.start(host: host)
        defer { pods.stop() }
        await pods.refresh()
        for _ in 0..<200 where pods.lastSync == nil { try await Task.sleep(for: .milliseconds(10)) }

        let dataset = try #require(pods.datasets.first { $0.name == "pods" })
        #expect(dataset.fields.contains { $0.name == "namespace" && $0.aliases == ["ns"] })
        let rows = try await dataset.rows(nil)
        #expect(rows.compactMap { $0["name"]?.string }.sorted() == ["web", "worker"])
        #expect(rows.first { $0["name"] == "worker" }?["status"] == "CrashLoopBackOff")

        let failing = try await QueryEngine(datasets: pods.datasets).run("pods ns:team-a status:crash")
        #expect(failing.rows.map { $0["name"] } == ["worker"])

        let query = try #require(try WidgetQuery("-status:Running | sort name", fields: PodsWidget.queryFields))
        #expect(await query.apply(to: pods.pods, row: { $0.queryRow() }).map(\.name) == ["worker"])
        #expect(PodsWidget.queryFields == PodSummary.queryFields)
    }
}
