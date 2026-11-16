import DashKit
import DashKitUI
import Foundation

/// A git worktree on this Mac: where it is, what it's on, how it stands against its upstream and
/// the repository's main branch, and its pull request. Read with local git only; `WorktreeStore`
/// keeps the latest scan.
struct Worktree: Codable, Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    /// The main checkout this worktree belongs to.
    let repo: String
    /// "owner/name" from the origin remote, when it's on GitHub.
    let slug: String?
    /// nil when detached.
    let branch: String?
    let head: String
    /// The repository's main checkout itself (not a linked worktree).
    let isMain: Bool
    /// Changed tracked files, and untracked files.
    let changed: Int
    let untracked: Int
    /// "origin/KAN-12", nil when the branch was never pushed.
    let upstream: String?
    /// Against its upstream: commits to push, commits to pull.
    let ahead: Int
    let behind: Int
    /// "origin/main"
    let base: String
    /// Against the main branch: its own commits, and the main branch's commits it doesn't have.
    let baseAhead: Int
    let baseBehind: Int
    let lastCommitAt: Date?
    let lastCommit: String
    let scannedAt: Date

    /// The ticket key in the branch name ("feat/kan-12-retry" → "KAN-12").
    var ticket: String? {
        guard let branch, let match = branch.range(of: #"[A-Za-z][A-Za-z0-9]+-\d+"#, options: .regularExpression) else { return nil }
        return branch[match].uppercased()
    }

    var name: String { (path as NSString).lastPathComponent }
    var isDirty: Bool { changed + untracked > 0 }
    /// Everything it has is already on the main branch (fast-forward or merged); squash merges
    /// show up through the pull request instead.
    var isOnBase: Bool { baseAhead == 0 && branch != nil }
}

/// A worktree's pull request, from the Pull Requests plugin's data.
struct WorktreePull: Codable, Equatable, Sendable {
    let repo: String
    let number: Int
    let title: String
    /// open, draft, merged, closed
    let state: String
    let url: String
    var label: String { "\(repo.split(separator: "/").last.map(String.init) ?? repo)#\(number)" }
}

/// What to say about a worktree, worst first: the badges the widget and the PR sheet show.
enum WorktreeStatus {
    struct Item: Equatable {
        let text: String
        let tone: Tone
        let help: String
    }

    static func items(_ tree: Worktree, pull: WorktreePull?) -> [Item] {
        var items: [Item] = []
        if let pull {
            switch pull.state {
            case "merged": items.append(.init(text: "PR merged", tone: .success, help: "\(pull.label) is merged."))
            case "closed": items.append(.init(text: "PR closed", tone: .neutral, help: "\(pull.label) was closed without merging."))
            case "draft": items.append(.init(text: "Draft \(pull.label)", tone: .info, help: pull.title))
            default: items.append(.init(text: pull.label, tone: .info, help: pull.title))
            }
        } else if !tree.isMain, tree.branch != nil {
            items.append(.init(text: "No PR", tone: .neutral, help: "No pull request from this branch."))
        }
        if tree.isDirty {
            items.append(.init(text: "\(tree.changed + tree.untracked) uncommitted", tone: .warning,
                               help: "\(tree.changed) changed, \(tree.untracked) untracked."))
        }
        if tree.upstream == nil, tree.branch != nil, !tree.isMain {
            items.append(.init(text: "Not pushed", tone: .warning, help: "The branch has no upstream on origin."))
        } else {
            if tree.ahead > 0 { items.append(.init(text: "↑\(tree.ahead) to push", tone: .warning, help: "Commits not on \(tree.upstream ?? "origin").")) }
            if tree.behind > 0 { items.append(.init(text: "↓\(tree.behind) to pull", tone: .warning, help: "\(tree.upstream ?? "origin") has commits you don't.")) }
            if tree.ahead == 0, tree.behind == 0, tree.upstream != nil { items.append(.init(text: "In sync", tone: .success, help: "Same as \(tree.upstream ?? "origin").")) }
        }
        if pull?.state != "merged", !tree.isMain, tree.baseBehind > 0, tree.baseAhead > 0 {
            items.append(.init(text: "Rebase: ↓\(tree.baseBehind)", tone: tree.baseBehind > 100 ? .danger : .warning,
                               help: "\(tree.base) has \(tree.baseBehind) commits this branch doesn't; rebase before merging."))
        }
        if pull == nil, !tree.isMain, tree.isOnBase, tree.baseBehind > 0, tree.lastCommitAt != nil {
            items.append(.init(text: "Already in \(tree.base)", tone: .success, help: "Every commit of this branch is on \(tree.base)."))
        }
        if removable(tree, pull: pull) {
            items.append(.init(text: "Safe to remove", tone: .success, help: "Merged and nothing uncommitted."))
        }
        return items
    }

    /// Its PR is merged and nothing is uncommitted: the worktree can go.
    static func removable(_ tree: Worktree, pull: WorktreePull?) -> Bool {
        !tree.isMain && !tree.isDirty && pull?.state == "merged"
    }
}

/// Local git only: lists every worktree of the clones it's given and reads each one's state.
enum WorktreeScanner {
    /// Git clones directly in `root` and one level below (organisation folders), plus `extra`.
    static func clones(root: String, extra: [String]) -> [URL] {
        let rootURL = URL(fileURLWithPath: (root as NSString).expandingTildeInPath)
        func isClone(_ url: URL) -> Bool {
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.appending(path: ".git").path, isDirectory: &directory) && directory.boolValue
        }
        var found: [URL] = []
        let first = (try? FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for child in first {
            if isClone(child) { found.append(child); continue }
            let second = (try? FileManager.default.contentsOfDirectory(at: child, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            found += second.filter(isClone)
        }
        for path in extra {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            if isClone(url) { found.append(url) }
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// `git worktree list --porcelain`: (path, head, branch) per worktree, the main checkout first.
    static func parseList(_ output: String) -> [(path: String, head: String, branch: String?)] {
        output.components(separatedBy: "\n\n").compactMap { block in
            var path: String?, head = "", branch: String?
            for line in block.split(separator: "\n").map(String.init) {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst("HEAD ".count)) }
                if line.hasPrefix("branch ") { branch = String(line.dropFirst("branch ".count)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line == "bare" { return nil }
            }
            return path.map { ($0, head, branch) }
        }
    }

    /// `git status --porcelain=v2 --branch`: upstream, ahead/behind, changed and untracked counts.
    static func parseStatus(_ output: String) -> (upstream: String?, ahead: Int, behind: Int, changed: Int, untracked: Int) {
        var upstream: String?, ahead = 0, behind = 0, changed = 0, untracked = 0
        for line in output.split(separator: "\n").map(String.init) {
            if line.hasPrefix("# branch.upstream ") { upstream = String(line.dropFirst("# branch.upstream ".count)) }
            if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                ahead = parts.first.flatMap { Int($0.dropFirst()) } ?? 0
                behind = parts.dropFirst().first.flatMap { Int($0.dropFirst()) } ?? 0
            }
            if line.hasPrefix("1 ") || line.hasPrefix("2 ") || line.hasPrefix("u ") { changed += 1 }
            if line.hasPrefix("? ") { untracked += 1 }
        }
        return (upstream, ahead, behind, changed, untracked)
    }

    /// Every worktree of `clone`, read with git.
    static func scan(_ clone: URL) async -> [Worktree] {
        guard let list = try? await Git.git(["worktree", "list", "--porcelain"], in: clone) else { return [] }
        let slug = try? await Git.gitHubSlug(clone)
        let base = await Git.remoteDefaultBranch(clone)
        let main = clone.standardizedFileURL.path
        var trees: [Worktree] = []
        for entry in parseList(list + "\n") {
            let url = URL(fileURLWithPath: entry.path)
            guard FileManager.default.fileExists(atPath: entry.path) else { continue }
            let status = parseStatus((try? await Git.git(["status", "--porcelain=v2", "--branch"], in: url)) ?? "")
            let counts = ((try? await Git.git(["rev-list", "--left-right", "--count", "\(base)...HEAD"], in: url)) ?? "0\t0")
                .split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
            let last = ((try? await Git.git(["log", "-1", "--format=%cI%x1f%s"], in: url)) ?? "").split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            trees.append(Worktree(
                path: entry.path, repo: main, slug: slug, branch: entry.branch, head: String(entry.head.prefix(12)),
                isMain: URL(fileURLWithPath: entry.path).standardizedFileURL.path == main,
                changed: status.changed, untracked: status.untracked, upstream: status.upstream,
                ahead: status.ahead, behind: status.behind, base: base,
                baseAhead: counts.count == 2 ? counts[1] : 0, baseBehind: counts.first ?? 0,
                lastCommitAt: last.first.flatMap { ISO8601DateFormatter().date(from: $0) }, lastCommit: last.count > 1 ? last[1] : "",
                scannedAt: .now))
        }
        return trees
    }
}
