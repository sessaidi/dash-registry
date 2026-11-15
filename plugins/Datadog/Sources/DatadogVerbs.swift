import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help monitor` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension DatadogIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("monitor", "list", tool: "datadog_monitors", summary: "Datadog monitors (query= to filter)."),
            DashQLVerb("monitor", "show", tool: "datadog_monitor", arguments: ["id"], summary: "One monitor."),
            DashQLVerb("datadog", "logs", tool: "datadog_logs_search", arguments: ["query"], summary: "Search Datadog logs."),
            DashQLVerb("datadog", "metrics", tool: "datadog_metrics_query", arguments: ["query"], summary: "Query a metric."),
            DashQLVerb("datadog", "events", tool: "datadog_events", summary: "Recent events."),
            DashQLVerb("datadog", "incidents", tool: "datadog_incidents", summary: "Incidents."),
            DashQLVerb("datadog", "services", tool: "datadog_services", summary: "APM services."),
            DashQLVerb("datadog", "slos", tool: "datadog_slos", summary: "SLOs."),
            DashQLVerb("datadog", "slo", tool: "datadog_slo_history", arguments: ["id"], summary: "An SLO's history."),
        ]
    }
}
