import DashKit
import Foundation

/// What DashQL and the knowledge graph read from Google Cloud's stored answers: log entries,
/// error groups and builds Dash fetched (one row each, with the project and their freshness), and
/// the Pub/Sub topics and subscriptions, tied to the topics the code names.
extension GCPIntegration {
    var datasets: [QueryDataset] {
        let freshness = [QueryDataset.Field("project", .string, "The project it was fetched from"), QueryDataset.Field("synced_at", .date, "When Dash fetched it"),
                         QueryDataset.Field("stale", .bool, "Older than its freshness window: fetch again for current data")]
        let newestFirst: (String) -> ([JSONValue]) -> [JSONValue] = { field in { $0.sorted { ($0[field]?.string ?? "") > ($1[field]?.string ?? "") } } }
        return [
            QueryDataset(name: "gcp_logs", summary: "Cloud Logging entries Dash fetched (data_fetch gcp.logs), newest first.",
                         fields: [.init("timestamp", .date), .init("severity"), .init("pod"), .init("container"), .init("resource"), .init("log"), .init("message")] + freshness) { [weak self] _ in
                newestFirst("timestamp")(self?.storedRows("logs") { $0["entries"]?.array ?? [] } ?? [])
            },
            QueryDataset(name: "gcp_errors", summary: "Error Reporting groups Dash fetched (data_fetch gcp.error_groups), most frequent first.",
                         fields: [.init("group"), .init("message"), .init("service"), .init("version"), .init("count", .number), .init("users", .number),
                                  .init("first_seen", .date), .init("last_seen", .date)] + freshness) { [weak self] _ in
                (self?.storedRows("error_groups") { $0.array ?? [] } ?? []).map { row in
                    row.merging(["count": row["count"]?.string.flatMap(Double.init).map(JSONValue.number) ?? row["count"] ?? .null,
                                 "users": row["users"]?.string.flatMap(Double.init).map(JSONValue.number) ?? row["users"] ?? .null])
                }.sorted { ($0["count"]?.double ?? 0) > ($1["count"]?.double ?? 0) }
            },
            QueryDataset(name: "gcp_builds", summary: "Cloud Build builds Dash fetched (data_fetch gcp.cloud_builds), newest first.",
                         fields: [.init("id"), .init("status"), .init("repo"), .init("branch"), .init("commit"), .init("started", .date), .init("finished", .date),
                                  .init("failure"), .init("log")] + freshness) { [weak self] _ in
                newestFirst("started")(self?.storedRows("cloud_builds") { $0.array ?? [] } ?? [])
            },
        ]
    }

    /// Rows from the stored answers of one kind, each with the fetch's `project`, `synced_at` and
    /// `stale`. Rows found in several answers (overlapping queries) come once, the newest copy.
    func storedRows(_ what: String, items: (JSONValue) -> [JSONValue]) -> [JSONValue] {
        guard let host, let resource = resources.first(where: { $0.what == what }) else { return [] }
        let rows = host.synced.rows(kind: resource.kind, scope: storeScope, maxAge: resource.freshFor) {
            ["fetcher": .string(resource.fetcherName), "input": $0.value["input"] ?? [:]]
        }
        var seen = Set<String>()
        return rows.sorted { ($0.freshness.syncedAt ?? .distantPast) > ($1.freshness.syncedAt ?? .distantPast) }.flatMap { value, freshness in
            let stamp: JSONValue = ["project": value["input"]?["project"] ?? .null, "synced_at": freshness.json["synced_at"] ?? .null, "stale": .bool(freshness.stale)]
            return items(value["data"] ?? .null).filter { seen.insert($0.jsonString()).inserted }.map { $0.merging(stamp) }
        }
    }

    /// Topics and subscriptions Dash fetched, as `topic` nodes linked to the code's (step 3's
    /// `topic:pubsub:<name>`), each subscription to its topic.
    var knowledge: [KnowledgeEntity] {
        guard let host else { return [] }
        var entities: [String: KnowledgeEntity] = [:]
        for record in host.synced.records(kind: "gcp.pubsub_topics", scope: storeScope) {
            guard let project = record.value["input"]?["project"]?.string else { continue }
            for topic in record.value["data"]?.array ?? [] {
                guard let name = topic["name"]?.string else { continue }
                let id = "topic:gcp:\(project)/topics/\(name)"
                entities[id] = KnowledgeEntity(id: id, kind: "topic", title: name, text: "Pub/Sub topic \(name) in Google Cloud project \(project).",
                                               updated: record.updatedAt, links: [KnowledgeLink(to: "topic:pubsub:\(name)", kind: "same_as")])
            }
        }
        for record in host.synced.records(kind: "gcp.pubsub_subscriptions", scope: storeScope) {
            guard let project = record.value["input"]?["project"]?.string else { continue }
            for subscription in record.value["data"]?.array ?? [] {
                guard let name = subscription["name"]?.string else { continue }
                let topic = subscription["topic"]?.string
                let delivery = subscription["push"]?.string.map { "pushes to \($0)" } ?? "pull"
                var links = [KnowledgeLink(to: "topic:pubsub:\(name)", kind: "same_as")]
                if let topic { links.append(KnowledgeLink(to: "topic:gcp:\(project)/topics/\(topic)", kind: "subscribes_to")) }
                let id = "topic:gcp:\(project)/subscriptions/\(name)"
                entities[id] = KnowledgeEntity(id: id, kind: "topic", title: name,
                                               text: "Pub/Sub subscription \(name)\(topic.map { " on topic \($0)" } ?? "") in Google Cloud project \(project) (\(delivery)).",
                                               updated: record.updatedAt, links: links)
            }
        }
        return entities.values.sorted { $0.id < $1.id }
    }
}
