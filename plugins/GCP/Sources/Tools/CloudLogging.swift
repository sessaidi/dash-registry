import DashKit
import Foundation

/// Cloud Logging reads: entries matching a filter, newest first. The `gcp.logs` fetcher stores
/// them; features (e.g. Workspaces) fetch and read them instead of talking to Google themselves.
extension GCPIntegration {
    struct LogsInput: Decodable {
        let project: String
        /// A Cloud Logging filter; combined with the convenience fields below.
        let filter: String?
        let namespace: String?
        let cluster: String?
        let pod: String?
        let container: String?
        /// DEFAULT, DEBUG, INFO, NOTICE, WARNING, ERROR, CRITICAL…
        let minSeverity: String?
        let text: String?
        /// ISO-8601 or "1h", "6h", "24h", "7d" back from now (default 1h).
        let since: String?
        let until: String?
        let limit: Int?
    }

    /// The filter for an input: Kubernetes container logs of a namespace by default.
    nonisolated static func logFilter(_ input: LogsInput, now: Date = .now) -> String {
        var parts: [String] = []
        if let filter = input.filter, !filter.isEmpty { parts.append("(\(filter))") }
        if input.namespace != nil || input.pod != nil || input.container != nil || input.cluster != nil, input.filter?.contains("resource.type") != true {
            parts.append(#"resource.type="k8s_container""#)
        }
        if let namespace = input.namespace { parts.append(#"resource.labels.namespace_name="\#(namespace)""#) }
        if let cluster = input.cluster { parts.append(#"resource.labels.cluster_name="\#(cluster)""#) }
        if let pod = input.pod { parts.append(#"resource.labels.pod_name="\#(pod)""#) }
        if let container = input.container { parts.append(#"resource.labels.container_name="\#(container)""#) }
        if let severity = input.minSeverity?.uppercased(), !severity.isEmpty { parts.append("severity>=\(severity)") }
        if let text = input.text, !text.isEmpty { parts.append("\"\(text.replacingOccurrences(of: "\"", with: "\\\""))\"") }
        parts.append(#"timestamp>="\#(timestamp(input.since, now: now, fallback: now.addingTimeInterval(-3600)))""#)
        if let until = input.until { parts.append(#"timestamp<="\#(timestamp(until, now: now, fallback: now))""#) }
        return parts.joined(separator: " AND ")
    }

    /// "1h", "30m", "7d" back from now, or an ISO-8601 date.
    nonisolated static func timestamp(_ text: String?, now: Date, fallback: Date) -> String {
        let formatter = ISO8601DateFormatter()
        guard let text, !text.isEmpty else { return formatter.string(from: fallback) }
        if let date = formatter.date(from: text) { return formatter.string(from: date) }
        let units: [Character: Double] = ["m": 60, "h": 3600, "d": 86_400]
        if let unit = text.last, let seconds = units[unit], let amount = Double(text.dropLast()) {
            return formatter.string(from: now.addingTimeInterval(-amount * seconds))
        }
        return formatter.string(from: fallback)
    }

    /// One entry, flattened: when, severity, where, and the message (text or JSON payload).
    nonisolated static func entry(_ item: JSONValue) -> JSONValue {
        let labels = item["resource"]?["labels"]
        let message = item["textPayload"]?.string
            ?? item["jsonPayload"]?["message"]?.string ?? item["jsonPayload"]?["msg"]?.string
            ?? item["jsonPayload"].map { $0.jsonString() } ?? item["protoPayload"].map { $0.jsonString() } ?? ""
        return [
            "timestamp": item["timestamp"] ?? .null, "severity": item["severity"] ?? .string("DEFAULT"),
            "pod": labels?["pod_name"] ?? .null, "container": labels?["container_name"] ?? .null,
            "resource": item["resource"]?["type"] ?? .null, "log": item["logName"] ?? .null,
            "message": .string(String(message.prefix(4000))), "insertId": item["insertId"] ?? .null,
        ]
    }

    func queryLogs(_ input: LogsInput) async throws -> JSONValue {
        let connection = try requireConnection()
        var request = URLRequest(url: URL(string: "https://logging.googleapis.com/v2/entries:list")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let filter = Self.logFilter(input, now: now())
        let body: JSONValue = ["resourceNames": .array([.string("projects/\(input.project)")]), "filter": .string(filter),
                               "orderBy": "timestamp desc", "pageSize": .number(Double(min(max(input.limit ?? 200, 1), 1000)))]
        request.httpBody = Data(body.jsonString().utf8)
        let (data, _) = try await connection.send(request, service: "Cloud Logging")
        let entries = try JSONValue.parse(data)["entries"]?.array ?? []
        let bodyText = body.jsonString()
        return ["filter": .string(filter), "count": .number(Double(entries.count)), "entries": .array(entries.map(Self.entry)),
                // The same request, to get the same entries yourself (raw), and the everyday command.
                "command": .string("curl -s -X POST 'https://logging.googleapis.com/v2/entries:list' -H \"Authorization: Bearer $(gcloud auth application-default print-access-token)\" -H 'Content-Type: application/json' -d '\(bodyText.replacingOccurrences(of: "'", with: "'\\''"))'"),
                "gcloud": .string("gcloud logging read '\(filter.replacingOccurrences(of: "'", with: "'\\''"))' --project \(input.project) --limit \(min(max(input.limit ?? 200, 1), 1000)) --order desc --format json")]
    }
}
