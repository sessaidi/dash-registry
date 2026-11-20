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
