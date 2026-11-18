import DashKit
import Foundation

/// What DashQL reads from AWS's stored answers: the CloudWatch Logs events Dash fetched, one row
/// each, with their group and freshness.
extension AWSIntegration {
    var datasets: [QueryDataset] {
        [
            QueryDataset(name: "aws_logs", summary: "CloudWatch Logs events Dash fetched (data_fetch aws.logs), newest first.",
                         fields: [.init("timestamp", .date), .init("group"), .init("stream"), .init("message"),
                                  .init("synced_at", .date, "When Dash fetched it"),
                                  .init("stale", .bool, "Older than its freshness window: fetch again for current data")]) { [weak self] _ in
                (self?.storedLogRows() ?? []).sorted { ($0["timestamp"]?.string ?? "") > ($1["timestamp"]?.string ?? "") }
            },
        ]
    }

    /// Events from every stored `aws.logs` answer, stamped with the group, `synced_at` and `stale`.
    /// Events found in several answers (overlapping windows) come once, the newest copy.
    func storedLogRows() -> [JSONValue] {
        guard let host, let resource = resources.first(where: { $0.what == "logs" }) else { return [] }
        let rows = host.synced.rows(kind: resource.kind, scope: storeScope, maxAge: resource.freshFor) {
            ["fetcher": .string(resource.fetcherName), "input": $0.value["input"] ?? [:]]
        }
        var seen = Set<String>()
        return rows.sorted { ($0.freshness.syncedAt ?? .distantPast) > ($1.freshness.syncedAt ?? .distantPast) }.flatMap { value, freshness in
            let data = value["data"] ?? .null
            let stamp: JSONValue = ["group": data["group"] ?? .null, "synced_at": freshness.json["synced_at"] ?? .null, "stale": .bool(freshness.stale)]
            let group = data["group"]?.string ?? ""
            return (data["events"]?.array ?? []).filter { seen.insert(group + "\n" + $0.jsonString()).inserted }.map { $0.merging(stamp) }
        }
    }
}
