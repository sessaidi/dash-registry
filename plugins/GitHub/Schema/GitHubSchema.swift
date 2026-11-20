import DashKit
import Foundation
import Ingestor
import SwiftData

/// GitHub's tables, in `github.store`. GitHub fills them (`ingestTables` maps items into rows);
/// the features that depend on GitHub compile this file too and read them
/// (`IngestDatabase.reading`), so keep it to the models.
enum GitHubSchema {
    static let name = "github"
    /// Bump when a model changes: features built with another version read through the readers
    /// until they're rebuilt with this file.
    static let version = 1
    static var models: [any PersistentModel.Type] { [GitHubPull.self, GitHubRun.self] }
}

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
}
