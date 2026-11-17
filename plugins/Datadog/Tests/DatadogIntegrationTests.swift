import DashKit
import DashKitTesting
import Foundation
import Testing

@MainActor
struct DatadogIntegrationTests {
    private func make(_ routes: [String: String] = [:], keys: Bool = true) -> (DatadogIntegration, String) {
        let site = "dd-\(UUID().uuidString.prefix(8).lowercased()).test"
        StubHTTP.serve("api.\(site)", routes: ["/api/v1/validate": #"{"valid": true}"#,
                                              "/api/v2/current_user": #"{"data": {"attributes": {"handle": "ada@example.com"}}}"#].merging(routes) { _, new in new })
        let defaults = UserDefaults(suiteName: "datadog-tests-\(UUID().uuidString)")!
        defaults.set(site, forKey: "datadog.site")
        let integration = DatadogIntegration(defaults: defaults, secret: { keys ? "key-\($0)" : nil }, session: StubHTTP.session)
        return (integration, "api.\(site)")
    }

    @Test func identityAndToolsAreReadOnly() {
        let (datadog, _) = make()
        #expect(datadog.id == "datadog" && datadog.layer == .integration && datadog.metadata.minimumDashKit == "2.4.0")
        #expect(DatadogPlugin.makeExtensions().allSatisfy { $0.metadata.version == "1.5.0" && $0.metadata.minimumDashKit == "2.4.0" })
        #expect(datadog.tools.map(\.name) == [
            "datadog_monitors", "datadog_monitor", "datadog_metrics_query", "datadog_logs_search", "datadog_events", "datadog_incidents",
            "datadog_dashboards", "datadog_dashboard", "datadog_slos", "datadog_slo_history", "datadog_hosts", "datadog_services", "datadog_api_read",
        ])
        #expect(datadog.tools.allSatisfy { $0.isForDashii && !$0.requiresApproval })
        #expect(DatadogPlugin.makeExtensions().map(\.id) == ["datadog", "datadog-monitors"])
    }

    @Test func verifiesTheKeysWithBothHeaders() async throws {
        let (datadog, host) = make()
        await datadog.verify()
        #expect(datadog.connectionState == .connected("Signed in as ada@example.com"))
        let request = try #require(StubHTTP.requests(host).first)
        #expect(request.url?.path() == "/api/v1/validate")
        #expect(request.value(forHTTPHeaderField: "DD-API-KEY") == "key-api_key")
        #expect(request.value(forHTTPHeaderField: "DD-APPLICATION-KEY") == "key-app_key")
        #expect(datadog.exports["site"]?.string?.hasSuffix(".test") == true)
    }

    @Test func withoutBothKeysItIsNotConnected() {
        let (datadog, _) = make(keys: false)
        #expect(!datadog.isConnected && datadog.connection == nil && datadog.connectionState == .notConfigured)
    }

    @Test func monitorsSortWorstFirst() async throws {
        let (datadog, _) = make(["/api/v1/monitor/search": #"""
            {"monitors": [
              {"id": 2, "name": "Disk", "status": "Warn", "type": "metric alert", "tags": ["env:prod"]},
              {"id": 1, "name": "Latency", "status": "Alert", "type": "query alert", "tags": ["service:api"], "last_triggered_ts": 1760000000}
            ]}
            """#])
        let sorted = DatadogMonitor.list(try await datadog.get("/api/v1/monitor/search")).sorted { ($0.severity, $0.name) < ($1.severity, $1.name) }
        #expect(sorted.map(\.id) == [1, 2])
        #expect(sorted.first?.lastTriggered == Date(timeIntervalSince1970: 1_760_000_000))
    }

    @Test func queriesEncodePlusAndBrackets() {
        let path = DatadogIntegration.path("/api/v1/query", ["query": "sum:a{env:prod}.as_count() + 1", "from": "1", "to": nil])
        #expect(path == "/api/v1/query?from=1&query=sum:a%7Benv:prod%7D.as_count()%20%2B%201")
    }

    @Test func bigOutputsAreCut() {
        let value = JSONValue.string(String(repeating: "y", count: DatadogIntegration.maxToolCharacters * 2))
        #expect(DatadogIntegration.limited(value).string?.hasSuffix("\n[truncated]") == true)
    }

    @Test func widgetFiltersAndDeclaresActions() {
        let monitors = [
            DatadogMonitor(id: 1, name: "API latency", status: "Alert", type: "", tags: ["service:api"], lastTriggered: nil),
            DatadogMonitor(id: 2, name: "Disk", status: "Warn", type: "", tags: ["service:db"], lastTriggered: nil),
            DatadogMonitor(id: 3, name: "Heartbeat", status: "No Data", type: "", tags: [], lastTriggered: nil),
        ]
        #expect(DatadogMonitorsWidget.shown(monitors, .init()).map(\.id) == [1, 2, 3])
        #expect(DatadogMonitorsWidget.shown(monitors, .init(filter: "service:db")).map(\.id) == [2])
        #expect(DatadogMonitorsWidget.shown(monitors, .init(showWarn: false, showNoData: false)).map(\.id) == [1])
        #expect(DatadogMonitorsWidget.actions.map(\.name) == ["filter", "select", "clear_selection", "refresh"])
        #expect(DatadogMonitorsWidget.actions.first { $0.name == "filter" }?.description.contains("Temporary") == true)
        #expect(WidgetType(DatadogMonitorsWidget.self).preview != nil)
    }
}
