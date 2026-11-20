import DashKit
import Foundation
import Ingestor
import SwiftData

/// GitHub's tables, in `github.store`. GitHub fills them; the features that depend on GitHub
/// compile this file too and read them (`IngestDatabase.reading`), so keep it to the models.
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
