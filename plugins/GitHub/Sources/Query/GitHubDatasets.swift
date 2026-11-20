import DashKit
import Foundation
import Ingestor
import SwiftData

/// What DashQL reads from GitHub: the pull requests, issues, runs and releases Dash fetched, one
/// row each (the newest copy when several fetches saw it), with the repository and freshness.
extension GitHubIntegration {
    var datasets: [QueryDataset] {
        let freshness = [QueryDataset.Field("repo", .string, "owner/name"), QueryDataset.Field("synced_at", .date, "When Dash fetched it"),
                         QueryDataset.Field("stale", .bool, "Older than GitHub's freshness window: fetch again for current data")]
        return [
            QueryDataset(name: "github_pulls", aliases: ["github_prs"], summary: "Pull requests Dash fetched from GitHub (data_fetch github.pulls or github.pull).",
                         fields: [.init("number", .number), .init("title"), .init("author"), .init("state"), .init("draft", .bool), .init("merged", .bool),
                                  .init("head"), .init("base"), .init("updated", .date), .init("url"), .init("labels", .list)] + freshness) { [weak self] _ in
                guard let self else { return [] }
                return tableRows(FetchDescriptor<GitHubPull>(sortBy: [SortDescriptor(\.rowKey)])) ?? storedRows(["pulls", "pull"]) { "\($0["number"]?.int ?? 0)" }
            },
            QueryDataset(name: "github_issues", summary: "Issues Dash fetched from GitHub (data_fetch github.issues).",
                         fields: [.init("number", .number), .init("title"), .init("author"), .init("state"), .init("labels", .list),
                                  .init("updated", .date), .init("url")] + freshness) { [weak self] _ in
                self?.storedRows(["issues"]) { "\($0["number"]?.int ?? 0)" } ?? []
            },
            QueryDataset(name: "github_runs", aliases: ["github_workflow_runs"], summary: "GitHub Actions runs Dash fetched (data_fetch github.workflow_runs).",
                         fields: [.init("id", .number), .init("workflow"), .init("branch"), .init("sha"), .init("event"), .init("status"),
                                  .init("conclusion"), .init("started", .date), .init("url")] + freshness) { [weak self] _ in
                guard let self else { return [] }
                return tableRows(FetchDescriptor<GitHubRun>(sortBy: [SortDescriptor(\.rowKey)])) ?? storedRows(["workflow_runs"]) { "\($0["id"]?.int ?? 0)" }
            },
            QueryDataset(name: "github_releases", summary: "Releases Dash fetched from GitHub (data_fetch github.releases).",
                         fields: [.init("tag"), .init("name"), .init("date", .date), .init("draft", .bool), .init("prerelease", .bool), .init("notes")] + freshness) { [weak self] _ in
                self?.storedRows(["releases"]) { $0["tag"]?.string ?? "" }
                    .sorted { ($0["date"]?.string ?? "") > ($1["date"]?.string ?? "") } ?? []
            },
        ]
    }

    /// Rows from the stored answers of these resources (lists and single objects), each with
    /// `repo`, `synced_at` and `stale`; one per repository and `id`, the most recently fetched.
    func storedRows(_ whats: [String], id: (JSONValue) -> String) -> [JSONValue] {
        let resources = ingestResources.filter { whats.contains(String($0.kind.dropFirst("github.".count))) }
        return ingestor.rows(resources, stamp: ["repo"], id: id)
    }
}
