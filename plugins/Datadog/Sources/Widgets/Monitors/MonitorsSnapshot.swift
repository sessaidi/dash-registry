import Foundation

/// Sample monitors for the widget's gallery preview: plain data, no Datadog.
extension DatadogMonitor {
    static let sample: [DatadogMonitor] = [
        DatadogMonitor(id: 1, name: "API p99 latency above 800 ms", status: "Alert", type: "metric alert", tags: ["service:api", "env:prod", "team:platform"], lastTriggered: .now.addingTimeInterval(-600)),
        DatadogMonitor(id: 2, name: "API 5xx rate above 2%", status: "Alert", type: "query alert", tags: ["service:api", "env:prod", "team:platform"], lastTriggered: .now.addingTimeInterval(-540)),
        DatadogMonitor(id: 3, name: "Checkout error rate", status: "Warn", type: "query alert", tags: ["service:checkout", "env:prod", "team:payments"], lastTriggered: .now.addingTimeInterval(-3_600)),
        DatadogMonitor(id: 4, name: "Postgres replication lag", status: "Warn", type: "metric alert", tags: ["service:postgres", "env:prod", "team:data"], lastTriggered: .now.addingTimeInterval(-7_200)),
        DatadogMonitor(id: 5, name: "Search cluster heap usage", status: "Warn", type: "metric alert", tags: ["service:search", "env:prod", "team:data"], lastTriggered: .now.addingTimeInterval(-14_400)),
        DatadogMonitor(id: 6, name: "Worker heartbeat", status: "No Data", type: "service check", tags: ["service:worker", "env:prod", "team:platform"], lastTriggered: nil),
        DatadogMonitor(id: 7, name: "Nightly export finished", status: "No Data", type: "event alert", tags: ["service:export", "env:prod", "team:data"], lastTriggered: .now.addingTimeInterval(-86_400)),
    ]
}

extension DatadogMonitor {
    /// The value of the first `key:value` tag, e.g. `service`.
    func tag(_ key: String) -> String? {
        tags.first { $0.hasPrefix(key + ":") }.map { String($0.dropFirst(key.count + 1)) }
    }
}
