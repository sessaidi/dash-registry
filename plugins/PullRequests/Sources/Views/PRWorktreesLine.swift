import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// The PR's worktrees on this Mac (same branch, or linked by hand), with what each needs, from the
/// Agents plugin's scan; and a menu to link another worktree to this PR.
struct PRWorktreesLine: View {
    let pr: PullRequest
    let host: any ExtensionContext
    @State private var trees: [JSONValue]?
    @State private var candidates: [JSONValue] = []
    @State private var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
            if let trees {
                if trees.isEmpty {
                    Text(note ?? "No worktree of this branch on this Mac.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(Array(trees.enumerated()), id: \.offset) { _, tree in
                        let status = (tree["status"]?.array ?? []).compactMap(\.string).filter { !$0.hasPrefix("#") && !$0.contains("#") }
                        Button {
                            if let path = tree["path"]?.string { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        } label: {
                            Badge(tree["name"]?.string ?? "worktree", tone: status.contains { $0.contains("uncommitted") || $0.contains("Rebase") || $0.contains("push") || $0.contains("pull") } ? .warning : .success,
                                  systemImage: "folder")
                        }
                        .buttonStyle(.plain)
                        .help(([tree["path"]?.string ?? ""] + status).joined(separator: "\n"))
                        Text(status.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if !candidates.isEmpty {
                    Menu("Link a Worktree") {
                        ForEach(Array(candidates.enumerated()), id: \.offset) { _, tree in
                            Button("\(tree["name"]?.string ?? "?") (\(tree["branch"]?.string ?? "detached"))") { link(tree["path"]?.string) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
                }
            } else {
                ProgressView().controlSize(.mini)
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let forBranch = tool("worktrees_for_branch") else {
            trees = []
            note = "Turn on the Agents plugin to see this branch's worktrees."
            return
        }
        trees = (try? await forBranch.run(["repo": .string(pr.repo), "branch": .string(pr.headRef), "pr": .number(Double(pr.number))]))?.array ?? []
        let listed = (try? await tool("worktrees_list")?.run(["repo": .string(pr.repo)]))?["worktrees"]?.array ?? []
        let shown = Set((trees ?? []).compactMap { $0["path"]?.string })
        candidates = listed.filter { $0["main_checkout"]?.bool != true && !shown.contains($0["path"]?.string ?? "") }
    }

    private func link(_ path: String?) {
        guard let path, let linker = tool("worktree_link") else { return }
        Task {
            _ = try? await linker.run(["path": .string(path), "pr": .string("\(pr.repo)#\(pr.number)")])
            await load()
        }
    }

    private func tool(_ name: String) -> DashiiTool? {
        host.extensions.filter { host.isEnabled($0) }.flatMap(\.tools).first { $0.name == name }
    }
}
