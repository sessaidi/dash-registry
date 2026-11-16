import DashKit
import Foundation
import Testing

/// Worktrees: read with local git, their state worded, linked to pull requests.
@MainActor
@Suite(.serialized)
struct WorktreeTests {
    @Test func parsesWorktreeListAndStatus() {
        let list = "worktree /code/api\nHEAD abc\nbranch refs/heads/main\n\nworktree /code/api/.worktrees/KAN-12\nHEAD def\nbranch refs/heads/feat/kan-12-retry\n\nworktree /code/bare\nbare\n"
        let parsed = WorktreeScanner.parseList(list)
        #expect(parsed.map(\.path) == ["/code/api", "/code/api/.worktrees/KAN-12"] && parsed[1].branch == "feat/kan-12-retry")
        let status = WorktreeScanner.parseStatus("# branch.oid abc\n# branch.head x\n# branch.upstream origin/x\n# branch.ab +2 -5\n1 .M N... 100644 100644 100644 a b f.go\n? new.go\n? other.go")
        #expect(status.upstream == "origin/x" && status.ahead == 2 && status.behind == 5 && status.changed == 1 && status.untracked == 2)
    }

    @Test func statusSaysWhatEachWorktreeNeeds() {
        let tree = WorktreeSample.tree("KAN-12", branch: "feat/kan-12-retry", changed: 2, upstream: "origin/feat/kan-12-retry", ahead: 1, behind: 3, baseAhead: 4, baseBehind: 120)
        #expect(tree.ticket == "KAN-12")
        let texts = WorktreeStatus.items(tree, pull: nil).map(\.text)
        #expect(texts == ["No PR", "2 uncommitted", "↑1 to push", "↓3 to pull", "Rebase: ↓120"])
        let merged = WorktreeSample.tree("KAN-3", branch: "KAN-3", upstream: "origin/KAN-3", baseAhead: 2, baseBehind: 10)
        let pull = WorktreePull(repo: "acme/billing-api", number: 790, title: "Flags", state: "merged", url: "")
        #expect(WorktreeStatus.items(merged, pull: pull).map(\.text) == ["PR merged", "In sync", "Safe to remove"])
        #expect(WorktreeSample.tree("x", branch: "x").isMain == false && WorktreeStatus.items(WorktreeSample.tree("x", branch: "x"), pull: nil).first?.text == "No PR")
    }

    @Test func scansARealRepositoryWithAWorktree() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "worktrees-\(UUID())")
        let repo = root.appending(path: "api")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "me@example.com"], ["config", "user.name", "Me"],
                          ["commit", "-q", "--allow-empty", "-m", "start"], ["worktree", "add", "-q", "-b", "KAN-9-docs", ".worktrees/KAN-9", "main"]] {
            try await Git.git(arguments, in: repo)
        }
        try "x".write(to: repo.appending(path: ".worktrees/KAN-9/notes.md"), atomically: true, encoding: .utf8)
        let store = WorktreeStore(defaults: UserDefaults(suiteName: "worktrees-\(UUID())")!)
        store.fetchRemotes = false
        await store.refresh(roots: [root.path], repositories: [], host: nil)
        #expect(store.items.count == 2 && store.items.first?.isMain == true)
        let tree = try #require(store.items.first { !$0.isMain })
        #expect(tree.branch == "KAN-9-docs" && tree.ticket == "KAN-9" && tree.untracked == 1 && tree.upstream == nil)
        #expect(WorktreeStatus.items(tree, pull: nil).map(\.text).contains("Not pushed"))
    }

    @Test func clonesWithoutWorktreesAreSkippedUnlessNamed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "clones-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["org/plain", "org/busy"] {
            let repo = root.appending(path: name)
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            for arguments in [["init", "-q", "-b", "main"], ["config", "user.email", "me@example.com"], ["config", "user.name", "Me"], ["commit", "-q", "--allow-empty", "-m", "start"]] {
                try await Git.git(arguments, in: repo)
            }
        }
        try await Git.git(["worktree", "add", "-q", "-b", "KAN-1", ".worktrees/KAN-1", "main"], in: root.appending(path: "org/busy"))
        let found = WorktreeScanner.clones(roots: [root.path], extra: [])
        #expect(found.map(\.lastPathComponent) == ["busy"])
        #expect(WorktreeScanner.clones(roots: [root.path], extra: [root.appending(path: "org/plain").path]).count == 2)
    }

    @Test func pullsComeFromOpenPRsOrAManualLink() async throws {
        let store = WorktreeStore(defaults: UserDefaults(suiteName: "worktrees-\(UUID())")!)
        let open: [JSONValue] = [["repo": "acme/billing-api", "number": 812, "title": "Retry", "draft": false, "url": "https://github.com/acme/billing-api/pull/812", "branch": "KAN-12-retry"]]
        #expect(WorktreeStore.pull(open[0], repo: "acme/billing-api") == WorktreePull(repo: "acme/billing-api", number: 812, title: "Retry", state: "open", url: "https://github.com/acme/billing-api/pull/812"))
        #expect(WorktreeStore.pull(link: "acme/billing-api#812", in: open)?.title == "Retry")
        #expect(WorktreeStore.pull(link: "acme/billing-api#99", in: open)?.url == "https://github.com/acme/billing-api/pull/99")
        #expect(WorktreeStore.pull(link: "nonsense", in: open) == nil)
        await store.link("/code/x", to: "acme/billing-api#812", host: nil)
        #expect(store.links["/code/x"] == "acme/billing-api#812")
    }
}

struct PullReferenceTests {
    @Test func pullReferences() {
        #expect(WorktreeStore.isPullReference("acme/billing-api#812"))
        #expect(!WorktreeStore.isPullReference("billing-api#812") && !WorktreeStore.isPullReference("acme/billing-api#"))
    }
}
