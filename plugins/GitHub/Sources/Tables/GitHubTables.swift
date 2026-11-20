import DashKit
import Foundation
import Ingestor
import SwiftData

/// A pull request GitHub's fetchers stored (`github.pulls`, `github.pull`), one row per repository
/// and number, in the integration's own database (`github.store`).
@Model
final class GitHubPull: IngestRow {
    #Index<GitHubPull>([\.rowKey], [\.repo, \.state])

    var rowKey = ""
    var item = ""
    var syncedAt = Date.distantPast
    var repo = ""
    var number = 0
    var title = ""
    var author = ""
    var state = ""
    var draft = false
    var merged = false
    var head = ""
    var base = ""
    var updated: Date?
    var url = ""
    var labels: [String] = []

    init() {}

    func update(from item: JSONValue) {
        repo = item["repo"]?.string ?? ""
        number = item["number"]?.int ?? 0
        title = item["title"]?.string ?? ""
        author = item["author"]?.string ?? ""
        state = item["state"]?.string ?? ""
        draft = item["draft"]?.bool ?? false
        merged = item["merged"]?.bool ?? false
        head = item["head"]?.string ?? ""
        base = item["base"]?.string ?? ""
        updated = item["updated"].flatMap { DashDate.parse($0) }
        url = item["url"]?.string ?? ""
        labels = item["labels"]?.array?.compactMap(\.string) ?? []
    }
}

/// A GitHub Actions run the fetchers stored (`github.workflow_runs`), one row per repository and id.
@Model
final class GitHubRun: IngestRow {
    #Index<GitHubRun>([\.rowKey], [\.repo, \.conclusion])

    var rowKey = ""
    var item = ""
    var syncedAt = Date.distantPast
    var repo = ""
    var runID = 0
    var workflow = ""
    var branch = ""
    var sha = ""
    var event = ""
    var status = ""
    var conclusion = ""
    var started: Date?
    var url = ""

    init() {}

    func update(from item: JSONValue) {
        repo = item["repo"]?.string ?? ""
        runID = item["id"]?.int ?? 0
        workflow = item["workflow"]?.string ?? ""
        branch = item["branch"]?.string ?? ""
        sha = item["sha"]?.string ?? ""
        event = item["event"]?.string ?? ""
        status = item["status"]?.string ?? ""
        conclusion = item["conclusion"]?.string ?? ""
        started = item["started"].flatMap { DashDate.parse($0) }
        url = item["url"]?.string ?? ""
    }
}

extension GitHubIntegration {
    static let tableModels: [any PersistentModel.Type] = [GitHubPull.self, GitHubRun.self]

    /// The tables and the resources that fill them.
    var ingestTables: [IngestTable] {
        let resources = ingestResources
        func filling(_ whats: [String]) -> [IngestResource] { resources.filter { whats.contains(String($0.kind.dropFirst("github.".count))) } }
        return [
            IngestTable(GitHubPull.self, from: filling(["pulls", "pull"]), stamp: ["repo"]) { "\($0["number"]?.int ?? 0)" },
            IngestTable(GitHubRun.self, from: filling(["workflow_runs"]), stamp: ["repo"]) { "\($0["id"]?.int ?? 0)" },
        ]
    }

    /// Opens `github.store` (made again, then rebuilt from the cache, when it can't be opened).
    func openDatabase() {
        do {
            database = try IngestDatabase(name: "github", models: Self.tableModels, folder: databaseFolder, inMemory: databaseFolder == nil)
            try ingestor.syncTables()
        } catch {
            database = nil
        }
    }

    /// A table's rows as DashQL rows: the stored item with `synced_at` and `stale`.
    func tableRows<Row: IngestRow>(_ descriptor: FetchDescriptor<Row>) -> [JSONValue]? {
        guard let database, let rows = try? database.context.fetch(descriptor) else { return nil }
        return rows.map { row in
            let freshness = Freshness(syncedAt: row.syncedAt, maxAge: maxAge, refresh: nil, now: now())
            let item = (try? JSONValue.parse(Data(row.item.utf8))) ?? [:]
            return item.merging(["synced_at": freshness.json["synced_at"] ?? .null, "stale": .bool(freshness.stale)])
        }
    }
}
