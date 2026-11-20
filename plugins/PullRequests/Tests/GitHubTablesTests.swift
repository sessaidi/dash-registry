import DashKit
import Foundation
import Ingestor
import SwiftData
import Testing

/// GitHub's tables read here directly: only when GitHub publishes its database with the schema
/// this plugin was built with, read-only, the branch's runs newest first.
@MainActor
struct GitHubTablesTests {
    @Test func theFeatureReadsGitHubsRunsWhenTheSchemaMatches() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "pr-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        // What GitHub stored.
        let github = try IngestDatabase(name: "github", models: GitHubSchema.models, folder: folder)
        for (id, branch, conclusion, minutes) in [(1, "feature/x", "failure", 30), (2, "feature/x", "success", 10), (3, "main", "success", 5)] {
            let run = GitHubRun()
            run.rowKey = "acme/api#\(id)"
            run.repo = "acme/api"
            run.runID = id
            run.branch = branch
            run.status = "completed"
            run.conclusion = conclusion
            run.started = .now.addingTimeInterval(-Double(minutes * 60))
            github.context.insert(run)
        }
        try github.context.save()

        let harness = Harness()
        #expect(harness.feature.githubDatabase == nil)
        let export: JSONValue = ["name": "github", "folder": .string(folder.path()), "schema": .number(Double(GitHubSchema.version))]
        harness.github.exports = harness.github.exports.merging(["database": export.merging(["schema": .number(Double(GitHubSchema.version + 1))])])
        #expect(harness.feature.githubDatabase == nil)

        harness.github.exports = harness.github.exports.merging(["database": export])
        let database = try #require(harness.feature.githubDatabase)
        #expect(database.isReadOnly && harness.feature.githubDatabase === database)
        let runs = try database.context.fetch(PullRequestsFeature.branchRuns(repo: "Acme/API", branch: "feature/x"))
        #expect(runs.map(\.runID) == [2, 1])
        #expect(BranchRunsView.label(runs[1]) == "failure" && BranchRunsView.tone(runs[1]) == .danger && BranchRunsView.tone(runs[0]) == .success)
    }
}
