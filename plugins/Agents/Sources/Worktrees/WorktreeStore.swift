import DashKit
import Foundation
import Observation

/// The worktrees on this Mac and their pull requests. Scans with local git every few minutes,
/// fetches the clones' remotes now and then (so "to pull" and "rebase" are true), and reads pull
/// requests from the Pull Requests plugin: open ones from its database, merged or closed ones by
/// asking it to fetch (`github.branch_pulls`). A worktree can also be linked to a PR by hand.
@MainActor
@Observable
final class WorktreeStore {
    private(set) var items: [Worktree] = []
    /// The pull request of each worktree path (found or linked).
    private(set) var pulls: [String: WorktreePull]
    /// Worktree path → "owner/name#123", set by the user.
    private(set) var links: [String: String]
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    var lastError: String?

    /// Fetch the clones' remotes (git fetch) every `fetchMinutes`, so ahead/behind are current.
    var fetchRemotes: Bool { didSet { defaults.set(fetchRemotes, forKey: "agents.worktrees.fetch") } }
    static let fetchMinutes = 30.0
    /// Merged or closed PRs are looked up at most this often per worktree.
    static let pullCheckHours = 6.0

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastFetch: [String: Date] = [:]
    @ObservationIgnored private var lastPullCheck: [String: Date] = [:]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        fetchRemotes = defaults.object(forKey: "agents.worktrees.fetch") as? Bool ?? true
        links = defaults.dictionary(forKey: "agents.worktrees.links") as? [String: String] ?? [:]
        pulls = defaults.data(forKey: "agents.worktrees.pulls").flatMap { try? JSONDecoder().decode([String: WorktreePull].self, from: $0) } ?? [:]
        items = defaults.data(forKey: "agents.worktrees.items").flatMap { try? JSONDecoder().decode([Worktree].self, from: $0) } ?? []
    }

    func pull(for tree: Worktree) -> WorktreePull? { pulls[tree.path] }

    /// Rescans every clone under the code folders (and the given repositories), then their PRs.
    func refresh(roots: [String], repositories: [String], host: (any ExtensionContext)?) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let clones = WorktreeScanner.clones(roots: roots, extra: repositories)
        if fetchRemotes {
            for clone in clones where Date.now.timeIntervalSince(lastFetch[clone.path] ?? .distantPast) > Self.fetchMinutes * 60 {
                lastFetch[clone.path] = .now
                _ = try? await Git.git(["fetch", "--prune", "--quiet", "origin"], in: clone)
            }
        }
        var found: [Worktree] = []
        for clone in clones { found += await WorktreeScanner.scan(clone) }
        items = found.sorted { ($0.repo, $0.isMain ? 0 : 1, $0.name) < ($1.repo, $1.isMain ? 0 : 1, $1.name) }
        lastScan = .now
        defaults.set(try? JSONEncoder().encode(items), forKey: "agents.worktrees.items")
        if let host { await refreshPulls(host: host) }
    }

    /// Open PRs from the Pull Requests plugin's database; merged or closed ones fetched on request.
    func refreshPulls(host: any ExtensionContext, now: Date = .now) async {
        let open = (try? await Self.tool("github_list_prs", host: host))?.array ?? []
        for tree in items where !tree.isMain {
            guard let slug = tree.slug else { continue }
            if let link = links[tree.path], let pull = Self.pull(link: link, in: open) {
                pulls[tree.path] = pull
                continue
            }
            if let branch = tree.branch, let match = open.first(where: { $0["repo"]?.string == slug && $0["branch"]?.string == branch }) {
                pulls[tree.path] = Self.pull(match, repo: slug)
                continue
            }
            // Not open: ask the Pull Requests plugin to fetch the branch's PRs (merged, closed).
            guard let branch = links[tree.path] == nil ? tree.branch : nil,
                  now.timeIntervalSince(lastPullCheck[tree.path] ?? .distantPast) > Self.pullCheckHours * 3600,
                  host.fetchers.contains(where: { $0.name == "github.branch_pulls" }) else { continue }
            lastPullCheck[tree.path] = now
            if let receipt = try? await host.fetch("github.branch_pulls", ["repo": .string(slug), "branch": .string(branch)]) {
                pulls[tree.path] = (receipt["pulls"]?.array?.first).map { Self.pull($0, repo: slug) }
            }
        }
        defaults.set(try? JSONEncoder().encode(pulls), forKey: "agents.worktrees.pulls")
    }

    /// Links a worktree to a PR ("owner/name#123"), or unlinks it (nil).
    func link(_ path: String, to pull: String?, host: (any ExtensionContext)?) async {
        links[path] = pull
        if pull == nil { pulls[path] = nil; lastPullCheck[path] = nil }
        defaults.set(links, forKey: "agents.worktrees.links")
        if let host { await refreshPulls(host: host) }
    }

    /// Removes a merged, clean worktree (`git worktree remove`), after the user agrees.
    func remove(_ tree: Worktree, host: (any ExtensionContext)?) async throws {
        guard WorktreeStatus.removable(tree, pull: pulls[tree.path]) else { throw ToolError("Only a merged, clean worktree can be removed here.") }
        let allowed = await host?.permissions.ask(icon: "trash", title: "Remove the worktree \(tree.name)?",
                                                  message: "\(tree.path) is deleted from this Mac (its branch and commits stay in the repository).",
                                                  allowLabel: "Remove", denyLabel: "Cancel") ?? false
        guard allowed else { return }
        try await Git.git(["worktree", "remove", tree.path], in: URL(fileURLWithPath: tree.repo))
        items.removeAll { $0.path == tree.path }
        pulls[tree.path] = nil
    }

    /// A row of `github_list_prs` as a worktree's pull.
    static func pull(_ row: JSONValue, repo: String) -> WorktreePull {
        let state = row["merged"]?.bool == true ? "merged" : row["state"]?.string == "closed" ? "closed" : row["draft"]?.bool == true ? "draft" : "open"
        return WorktreePull(repo: row["repo"]?.string ?? repo, number: row["number"]?.int ?? 0, title: row["title"]?.string ?? "",
                            state: state, url: row["url"]?.string ?? "")
    }

    /// A linked PR ("owner/name#123") among the open ones, else a bare link to it.
    static func pull(link: String, in open: [JSONValue]) -> WorktreePull? {
        let parts = link.split(separator: "#")
        guard parts.count == 2, let number = Int(parts[1]) else { return nil }
        let repo = String(parts[0])
        if let row = open.first(where: { $0["repo"]?.string == repo && $0["number"]?.int == number }) { return pull(row, repo: repo) }
        return WorktreePull(repo: repo, number: number, title: "", state: "open", url: "https://github.com/\(repo)/pull/\(number)")
    }

    /// "owner/name#123"
    nonisolated static func isPullReference(_ text: String) -> Bool {
        text.range(of: #"^[\w.-]+/[\w.-]+#\d+$"#, options: .regularExpression) != nil
    }

    static func tool(_ name: String, host: any ExtensionContext, _ input: JSONValue = [:]) async throws -> JSONValue? {
        guard let tool = host.extensions.filter({ host.isEnabled($0) }).flatMap(\.tools).first(where: { $0.name == name }) else { return nil }
        return try await tool.run(input)
    }
}
