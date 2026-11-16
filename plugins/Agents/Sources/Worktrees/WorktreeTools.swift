import DashKit
import Foundation
import SwiftUI

/// Dashii's view of the worktrees: read from the last scan (no git or GitHub at question time).
extension AgentsExtension {
    private struct ListInput: Decodable { let repo: String?; let ticket: String?; let attention: Bool? }
    private struct BranchInput: Decodable { let repo: String; let branch: String; let pr: Int? }
    private struct LinkInput: Decodable { let path: String; let pr: String? }

    func worktreeJSON(_ tree: Worktree) -> JSONValue {
        let pull = worktrees.pull(for: tree)
        return ["path": .string(tree.path), "name": .string(tree.name), "repo": tree.slug.map(JSONValue.string) ?? .string(tree.repo),
                "branch": tree.branch.map(JSONValue.string) ?? .null, "ticket": tree.ticket.map(JSONValue.string) ?? .null,
                "main_checkout": .bool(tree.isMain), "changed": .number(Double(tree.changed)), "untracked": .number(Double(tree.untracked)),
                "upstream": tree.upstream.map(JSONValue.string) ?? .null, "to_push": .number(Double(tree.ahead)), "to_pull": .number(Double(tree.behind)),
                "base": .string(tree.base), "commits_not_on_base": .number(Double(tree.baseAhead)), "base_commits_missing": .number(Double(tree.baseBehind)),
                "last_commit": .string(tree.lastCommit), "last_commit_at": tree.lastCommitAt.map { .string($0.formatted(.iso8601)) } ?? .null,
                "pr": pull.map { ["repo": .string($0.repo), "number": .number(Double($0.number)), "state": .string($0.state), "title": .string($0.title), "url": .string($0.url)] } ?? .null,
                "linked_by_hand": .bool(worktrees.links[tree.path] != nil),
                "status": .array(WorktreeStatus.items(tree, pull: pull).map { .string($0.text) }),
                "scanned_at": .string(tree.scannedAt.formatted(.iso8601))]
    }

    var worktreeTools: [DashiiTool] {
        [
            DashiiTool(
                name: "worktrees_list",
                description: "Every git worktree on this Mac (from Dash's last scan, every 5 minutes): branch, ticket, uncommitted files, commits to push or pull, how far behind the main branch (rebase), and its pull request (open, draft, merged, closed). Use it instead of guessing folder names.",
                properties: ["repo": JSONSchema.string("Optional owner/name or folder name filter."),
                             "ticket": JSONSchema.string("Optional ticket key filter."),
                             "attention": JSONSchema.boolean("Only worktrees needing something: uncommitted, unpushed, behind, rebase, merged (removable).")]
            ) { [weak self] input in
                guard let self else { return [] }
                let request = try input.toolInput(ListInput.self)
                let rows = worktrees.items.filter { tree in
                    (request.repo.map { repo in tree.slug == repo || tree.repo.hasSuffix("/" + repo) || tree.name == repo } ?? true)
                        && (request.ticket.map { tree.ticket == $0.uppercased() } ?? true)
                        && (request.attention != true || WorktreeStatus.items(tree, pull: worktrees.pull(for: tree)).contains { $0.tone != .success && $0.tone != .info && $0.tone != .neutral })
                }
                return ["scanned_at": worktrees.lastScan.map { .string($0.formatted(.iso8601)) } ?? .null, "worktrees": .array(rows.map(worktreeJSON))]
            },
            DashiiTool(
                name: "worktrees_for_branch",
                description: "The worktrees of a branch (or linked by hand to a pull request) in a repository, with their state.",
                properties: ["repo": JSONSchema.string("owner/name"), "branch": JSONSchema.string("Branch name."), "pr": JSONSchema.integer("Optional PR number: also worktrees linked to it.")],
                required: ["repo", "branch"]
            ) { [weak self] input in
                guard let self else { return [] }
                let request = try input.toolInput(BranchInput.self)
                let link = request.pr.map { "\(request.repo)#\($0)" }
                return .array(worktrees.items.filter { tree in
                    (tree.slug == request.repo && tree.branch == request.branch) || (link != nil && worktrees.links[tree.path] == link)
                }.map(worktreeJSON))
            },
            DashiiTool(
                name: "worktree_link",
                description: "Link a worktree to a pull request (owner/name#123) when its branch name doesn't match the PR's, or unlink it (no pr). Local to Dash.",
                properties: ["path": JSONSchema.string("The worktree's path."), "pr": JSONSchema.string("owner/name#123; leave out to unlink.")],
                required: ["path"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(LinkInput.self)
                guard worktrees.items.contains(where: { $0.path == request.path }) else { throw ToolError("No worktree at \(request.path).") }
                if let pr = request.pr, !WorktreeStore.isPullReference(pr) { throw ToolError("Give the PR as owner/name#123.") }
                await worktrees.link(request.path, to: request.pr, host: host)
                return "linked"
            },
        ]
    }
}

/// Settings › Agents › Worktrees.
struct WorktreesSettingsSection: View {
    @Bindable var store: WorktreeStore
    let scan: () -> Void

    var body: some View {
        Section {
            Toggle("Fetch the repositories' remotes every \(Int(WorktreeStore.fetchMinutes)) minutes", isOn: $store.fetchRemotes)
            HStack {
                if let last = store.lastScan {
                    Text("\(store.items.count) worktrees · scanned \(last.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if store.isScanning { ProgressView().controlSize(.small) }
                Button("Scan Now", action: scan).disabled(store.isScanning)
            }
        } header: {
            Text("Worktrees")
        } footer: {
            Text("Dash lists every worktree of the clones in the code folder with local git: uncommitted files, commits to push or pull, how far behind the main branch. Fetching keeps that true against origin (git fetch only reads). Pull requests come from the Pull Requests plugin.")
        }
    }
}
