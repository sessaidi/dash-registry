import DashKit
import Foundation
import Ingestor
import SwiftData

extension GitHubIntegration {
    /// For features that read the tables (`IngestDatabase.reading`): the file and its schema
    /// version. Absent while the tables are only in memory.
    var databaseExport: JSONValue? {
        guard let databaseFolder, database != nil else { return nil }
        return ["name": .string(GitHubSchema.name), "folder": .string(databaseFolder.path()), "schema": .number(Double(GitHubSchema.version))]
    }

    /// The tables, the resources that fill them, and how a stored item fills a row.
    var ingestTables: [IngestTable] {
        let resources = ingestResources
        func filling(_ whats: [String]) -> [IngestResource] { resources.filter { whats.contains(String($0.kind.dropFirst("github.".count))) } }
        return [
            IngestTable(GitHubPull.self, from: filling(["pulls", "pull"]), stamp: ["repo"], id: "number") { row, item in
                row.repo = item.string("repo")
                row.number = item.int("number")
                row.title = item.string("title")
                row.author = item.string("author")
                row.state = item.string("state")
                row.draft = item.bool("draft")
                row.merged = item.bool("merged")
                row.head = item.string("head")
                row.base = item.string("base")
                row.updated = item.date("updated")
                row.url = item.string("url")
                row.labels = item.strings("labels")
            },
            IngestTable(GitHubRun.self, from: filling(["workflow_runs"]), stamp: ["repo"], id: "id") { row, item in
                row.repo = item.string("repo")
                row.runID = item.int("id")
                row.workflow = item.string("workflow")
                row.branch = item.string("branch")
                row.sha = item.string("sha")
                row.event = item.string("event")
                row.status = item.string("status")
                row.conclusion = item.string("conclusion")
                row.started = item.date("started")
                row.url = item.string("url")
            },
        ]
    }

    /// Opens `github.store` (made again, then rebuilt from the cache, when it can't be opened).
    func openDatabase() {
        do {
            database = try IngestDatabase(name: GitHubSchema.name, models: GitHubSchema.models, folder: databaseFolder, inMemory: databaseFolder == nil)
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
