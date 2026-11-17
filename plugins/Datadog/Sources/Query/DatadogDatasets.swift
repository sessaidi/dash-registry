import DashKit
import Foundation

/// What DashQL reads from Datadog's stored answers: the log lines and events Dash fetched, one row
/// each, with the query that found them and their freshness. (`monitors` is the Monitors
/// feature's, which Dash checks every minute.)
extension DatadogIntegration {
    var datasets: [QueryDataset] {
        let freshness = [QueryDataset.Field("query", .string, "The fetch's query"), QueryDataset.Field("synced_at", .date, "When Dash fetched it"),
                         QueryDataset.Field("stale", .bool, "Older than its freshness window: fetch again for current data")]
        return [
            QueryDataset(name: "datadog_logs", summary: "Log lines Dash fetched from Datadog (data_fetch datadog.logs), newest first.",
                         fields: [.init("timestamp", .date), .init("service"), .init("status"), .init("host"), .init("message")] + freshness) { [weak self] _ in
                (self?.storedRows("logs") { $0 } ?? []).sorted { ($0["timestamp"]?.string ?? "") > ($1["timestamp"]?.string ?? "") }
            },
            QueryDataset(name: "datadog_events", summary: "Events (deploys, alerts, config changes) Dash fetched from Datadog (data_fetch datadog.events), newest first.",
                         fields: [.init("id"), .init("timestamp", .date), .init("title"), .init("message"), .init("service"), .init("tags", .list)] + freshness) { [weak self] _ in
                (self?.storedRows("events", row: Self.eventRow) ?? []).sorted { ($0["timestamp"]?.string ?? "") > ($1["timestamp"]?.string ?? "") }
            },
        ]
    }

    /// A row from a v2 event: its title, message and service wherever Datadog put them.
    nonisolated static func eventRow(_ event: JSONValue) -> JSONValue {
        let attributes = event["attributes"] ?? event
        let inner = attributes["attributes"]
        let message = String((attributes["message"]?.string ?? "").prefix(500))
        return ["id": event["id"] ?? .null, "timestamp": attributes["timestamp"] ?? inner?["timestamp"] ?? .null,
                "title": attributes["title"] ?? inner?["title"] ?? .null, "message": .string(message),
                "service": inner?["service"] ?? attributes["service"] ?? .null, "tags": attributes["tags"] ?? []]
    }

    /// Rows from the stored answers of one kind (lists under `data` or as-is), each with the
    /// fetch's `query`, `synced_at` and `stale`.
    func storedRows(_ what: String, row: (JSONValue) -> JSONValue) -> [JSONValue] {
        guard let host, let resource = resources.first(where: { $0.what == what }) else { return [] }
        let rows = host.synced.rows(kind: resource.kind, scope: storeScope, maxAge: resource.freshFor) {
            ["fetcher": .string(resource.fetcherName), "input": $0.value["input"] ?? [:]]
        }
        return rows.flatMap { value, freshness in
            let data = value["data"] ?? .null
            let items = data.array ?? data["data"]?.array ?? data["items"]?.array ?? []
            let stamp: JSONValue = ["query": value["input"]?["query"] ?? .null, "synced_at": freshness.json["synced_at"] ?? .null, "stale": .bool(freshness.stale)]
            return items.map { row($0).merging(stamp) }
        }
    }
}
