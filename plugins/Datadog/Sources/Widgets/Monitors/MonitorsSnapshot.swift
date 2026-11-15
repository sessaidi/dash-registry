import Foundation

/// Sample monitors for the widget's gallery preview: plain data, no Datadog.
extension DatadogMonitor {
    static let sample: [DatadogMonitor] = [
        DatadogMonitor(id: 1, name: "API p99 latency above 800 ms", status: "Alert", type: "metric alert", tags: ["service:api"], lastTriggered: .now.addingTimeInterval(-600)),
        DatadogMonitor(id: 2, name: "Checkout error rate", status: "Warn", type: "query alert", tags: ["service:checkout"], lastTriggered: .now.addingTimeInterval(-3_600)),
        DatadogMonitor(id: 3, name: "Worker heartbeat", status: "No Data", type: "service check", tags: ["service:worker"], lastTriggered: nil),
    ]
}
