import DashKit
import Foundation

/// Cloud Monitoring reads: a container's memory, CPU, restarts and disk over time, so a
/// restart can be traced to what led to it. The `gcp.metrics` fetcher stores them.
extension GCPIntegration {
    struct MetricsInput: Decodable {
        let project: String
        /// A preset (memory, memory_limit, cpu, cpu_limit, restarts, ephemeral_storage) or a full metric type.
        let metric: String
        let namespace: String?
        let pod: String?
        let container: String?
        let cluster: String?
        let since: String?
        /// Seconds per point (default 300).
        let step: Int?
    }

    nonisolated static let metricPresets: [String: String] = [
        "memory": "kubernetes.io/container/memory/used_bytes",
        "memory_limit": "kubernetes.io/container/memory/limit_utilization",
        "cpu": "kubernetes.io/container/cpu/core_usage_time",
        "cpu_limit": "kubernetes.io/container/cpu/limit_utilization",
        "restarts": "kubernetes.io/container/restart_count",
        "ephemeral_storage": "kubernetes.io/container/ephemeral_storage/used_bytes",
    ]

    nonisolated static func metricFilter(_ input: MetricsInput) -> String {
        let type = metricPresets[input.metric] ?? input.metric
        var parts = [#"metric.type="\#(type)""#]
        if let namespace = input.namespace { parts.append(#"resource.labels.namespace_name="\#(namespace)""#) }
        if let pod = input.pod { parts.append(#"resource.labels.pod_name="\#(pod)""#) }
        if let container = input.container { parts.append(#"resource.labels.container_name="\#(container)""#) }
        if let cluster = input.cluster { parts.append(#"resource.labels.cluster_name="\#(cluster)""#) }
        return parts.joined(separator: " AND ")
    }

    func queryMetrics(_ input: MetricsInput) async throws -> JSONValue {
        let connection = try requireConnection()
        let now = self.now()
        let type = Self.metricPresets[input.metric] ?? input.metric
        // Counters (CPU seconds, restarts) are turned into rates/deltas; gauges are averaged.
        let cumulative = type.hasSuffix("core_usage_time") || type.hasSuffix("restart_count")
        var components = URLComponents(string: "https://monitoring.googleapis.com/v3/projects/\(input.project)/timeSeries")!
        components.queryItems = [
            URLQueryItem(name: "filter", value: Self.metricFilter(input)),
            URLQueryItem(name: "interval.startTime", value: Self.timestamp(input.since ?? "6h", now: now, fallback: now.addingTimeInterval(-21_600))),
            URLQueryItem(name: "interval.endTime", value: ISO8601DateFormatter().string(from: now)),
            URLQueryItem(name: "aggregation.alignmentPeriod", value: "\(max(input.step ?? 300, 60))s"),
            URLQueryItem(name: "aggregation.perSeriesAligner", value: type.hasSuffix("restart_count") ? "ALIGN_DELTA" : cumulative ? "ALIGN_RATE" : "ALIGN_MEAN"),
        ]
        let (data, _) = try await connection.send(URLRequest(url: components.url!), service: "Cloud Monitoring")
        let series = try JSONValue.parse(data)["timeSeries"]?.array ?? []
        return ["metric": .string(type),
                "command": .string("curl -s '\(components.url!.absoluteString)' -H \"Authorization: Bearer $(gcloud auth application-default print-access-token)\""),
                "series": .array(series.prefix(30).map { item in
            let labels = item["resource"]?["labels"]
            let points = (item["points"]?.array ?? []).map { point -> JSONValue in
                let value = point["value"]
                let number = value?["doubleValue"]?.double ?? value?["int64Value"]?.string.flatMap(Double.init) ?? value?["int64Value"]?.double ?? 0
                return ["at": point["interval"]?["endTime"] ?? .null, "value": .number(number)]
            }
            let values = points.compactMap { $0["value"]?.double }
            return [
                "pod": labels?["pod_name"] ?? .null, "container": labels?["container_name"] ?? .null,
                "max": .number(values.max() ?? 0), "last": .number(values.first ?? 0),
                "points": .array(Array(points.prefix(200))),
            ]
        })]
    }
}
