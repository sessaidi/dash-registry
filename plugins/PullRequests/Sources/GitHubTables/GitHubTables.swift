import DashKit
import Foundation
import Ingestor
import SwiftData

/// GitHub's tables, read here directly: `github.store`, with the models compiled from GitHub's
/// schema file (`plugins/GitHub/Schema`). Read-only; GitHub alone fills them.
extension PullRequestsFeature {
    /// nil when GitHub doesn't publish its database or publishes another schema version (the
    /// readers still answer then).
    var githubDatabase: IngestDatabase? {
        guard let export = github?.exports["database"], export["schema"]?.int == GitHubSchema.version,
              let name = export["name"]?.string, let folder = export["folder"]?.string else { return nil }
        let key = name + "|" + folder
        if let opened = githubDatabaseCache, opened.key == key { return opened.database }
        let database = IngestDatabase.reading(name: name, models: GitHubSchema.models, folder: URL(filePath: folder))
        githubDatabaseCache = (key, database)
        return database
    }

    /// A branch's latest Actions runs, newest first.
    static func branchRuns(repo: String, branch: String, limit: Int = 5) -> FetchDescriptor<GitHubRun> {
        let repo = repo.lowercased()
        var descriptor = FetchDescriptor<GitHubRun>(predicate: #Predicate { $0.repo == repo && $0.branch == branch },
                                                    sortBy: [SortDescriptor(\.started, order: .reverse)])
        descriptor.fetchLimit = limit
        return descriptor
    }
}
