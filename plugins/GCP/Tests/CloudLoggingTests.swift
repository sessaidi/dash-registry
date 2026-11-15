import DashKit
import Foundation
import Testing

struct CloudLoggingTests {
    private func input(_ json: String) throws -> GCPIntegration.LogsInput {
        try JSONDecoder().decode(GCPIntegration.LogsInput.self, from: Data(json.utf8))
    }

    @Test func buildsNamespaceFilters() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!
        let filter = GCPIntegration.logFilter(try input(#"{"project":"acme-dev","namespace":"kan-12","pod":"api-1","minSeverity":"warning","text":"timeout","since":"6h"}"#), now: now)
        #expect(filter == #"resource.type="k8s_container" AND resource.labels.namespace_name="kan-12" AND resource.labels.pod_name="api-1" AND severity>=WARNING AND "timeout" AND timestamp>="2026-11-14T06:00:00Z""#)
        let custom = GCPIntegration.logFilter(try input(#"{"project":"p","filter":"resource.type=\"k8s_node\"","since":"2026-11-13T00:00:00Z"}"#), now: now)
        #expect(custom == #"(resource.type="k8s_node") AND timestamp>="2026-11-13T00:00:00Z""#)
    }

    @Test func flattensEntries() throws {
        let entry = GCPIntegration.entry(try JSONValue.parse(#"{"timestamp":"t","severity":"ERROR","resource":{"type":"k8s_container","labels":{"pod_name":"api-1","container_name":"api"}},"jsonPayload":{"message":"db timeout"}}"#))
        #expect(entry["message"]?.string == "db timeout" && entry["pod"]?.string == "api-1" && entry["severity"]?.string == "ERROR")
    }

    @Test func metricPresetsBecomeFilters() throws {
        let input = try JSONDecoder().decode(GCPIntegration.MetricsInput.self, from: Data(#"{"project":"p","metric":"memory","namespace":"kan-12","container":"api"}"#.utf8))
        #expect(GCPIntegration.metricFilter(input) == #"metric.type="kubernetes.io/container/memory/used_bytes" AND resource.labels.namespace_name="kan-12" AND resource.labels.container_name="api""#)
    }
}
