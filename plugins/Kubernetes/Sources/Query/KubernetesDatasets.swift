import DashKit
import Foundation

/// What DashQL reads from the cluster answers Dash stored: events and listed objects of the
/// current context, one row each (the newest copy when several fetches saw it), with their
/// freshness. (`pods` is the Pods feature's, refreshed every 30 seconds.)
extension KubernetesIntegration {
    var datasets: [QueryDataset] {
        let freshness = [QueryDataset.Field("context", .string, "Kubeconfig context"), QueryDataset.Field("synced_at", .date, "When Dash fetched it"),
                         QueryDataset.Field("stale", .bool, "Older than its freshness window: fetch again for current data")]
        return [
            QueryDataset(name: "k8s_events", summary: "Kubernetes events Dash fetched on the current context (data_fetch k8s.events), newest first.",
                         fields: [.init("namespace"), .init("object"), .init("type"), .init("reason"), .init("message"), .init("count", .number),
                                  .init("lastSeen", .date)] + freshness) { [weak self] _ in
                (self?.storedRows("events") { item, input in
                    "\(item["namespace"]?.string ?? input["namespace"]?.string ?? "")|\(item["object"]?.string ?? "")|\(item["reason"]?.string ?? "")|\(item["message"]?.string ?? "")"
                } ?? []).sorted { ($0["lastSeen"]?.string ?? "") > ($1["lastSeen"]?.string ?? "") }
            },
            QueryDataset(name: "k8s_objects", summary: "Kubernetes objects Dash listed on the current context (data_fetch k8s.list): deployments, services, jobs, nodes…",
                         fields: [.init("kind"), .init("name"), .init("namespace"), .init("created", .date), .init("ready"), .init("images", .list),
                                  .init("type"), .init("phase")] + freshness) { [weak self] _ in
                self?.storedRows("list") { item, input in
                    "\(input["kind"]?.string ?? "")|\(item["namespace"]?.string ?? "")|\(item["name"]?.string ?? "")"
                } ?? []
            },
        ]
    }

    /// Rows from the stored lists of one kind, each with the fetch's `kind` and `namespace` when the
    /// item lacks them, `context`, `synced_at` and `stale`; one per `id`, the most recently fetched.
    func storedRows(_ what: String, id: (JSONValue, JSONValue) -> String) -> [JSONValue] {
        guard let host, let resource = resources.first(where: { $0.what == what }) else { return [] }
        let rows = host.synced.rows(kind: resource.kind, scope: storeScope, maxAge: resource.freshFor) {
            ["fetcher": .string(resource.fetcherName), "input": $0.value["input"] ?? [:]]
        }
        var newest: [String: (row: JSONValue, at: Date)] = [:]
        for (value, freshness) in rows {
            let input = value["input"] ?? [:]
            let at = freshness.syncedAt ?? .distantPast
            for item in value["data"]?.array ?? value["data"]?["items"]?.array ?? [] {
                var stamp: [String: JSONValue] = ["context": activeContext.map(JSONValue.string) ?? .null,
                                                  "synced_at": freshness.json["synced_at"] ?? .null, "stale": .bool(freshness.stale)]
                if item["namespace"] == nil, let space = input["namespace"], space != "all" { stamp["namespace"] = space }
                if let kind = input["kind"] { stamp["kind"] = kind }
                let key = id(item, input)
                if let seen = newest[key], seen.at > at { continue }
                newest[key] = (item.merging(.object(stamp)), at)
            }
        }
        return newest.keys.sorted().compactMap { newest[$0]?.row }
    }
}
