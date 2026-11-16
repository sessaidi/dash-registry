import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// Worktrees: every git worktree on this Mac with what it needs (commit, push, pull, rebase) and
/// its pull request, grouped by repository.
struct WorktreesWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// Only worktrees that need something (uncommitted, unpushed, behind, rebase, removable).
        var attentionOnly: Bool
    }

    static let kind = "agents.worktrees"
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 24)
    static let displayName = "Worktrees"
    static let summary = "Every git worktree on this Mac: uncommitted files, commits to push or pull, rebase needed, and its pull request (open, merged, closed)."
    static let systemImage = "point.3.filled.connected.trianglepath.dotted"
    static let defaultSize = WidgetSize.large
    static let defaultConfig = Config(attentionOnly: false)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["attentionOnly": ["type": "boolean", "description": "Only worktrees that need something."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        WorktreesPanel(agents: context.host.ext(AgentsExtension.self), host: context.host, attentionOnly: config.attentionOnly)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Only worktrees that need something", isOn: config.attentionOnly)
    }

    static func preview(config: Config) -> some View {
        WorktreesLayout(trees: WorktreeSample.trees, pulls: WorktreeSample.pulls, attentionOnly: false, actions: .none).allowsHitTesting(false)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let agents = context.host.ext(AgentsExtension.self) else { return .null }
        return .array(agents.worktrees.items.map(agents.worktreeJSON))
    }
}

/// What a row's menu can do.
@MainActor
struct WorktreeActions {
    var open: (Worktree, String?) -> Void = { _, _ in }
    var openPR: (WorktreePull) -> Void = { _ in }
    var link: (Worktree) -> Void = { _ in }
    var remove: (Worktree) -> Void = { _ in }
    @MainActor static var none: WorktreeActions { WorktreeActions() }
}

struct WorktreesPanel: View {
    let agents: AgentsExtension?
    let host: any ExtensionContext
    @Binding var attentionOnly: Bool
    @State private var linking: Worktree?
    @State private var error: String?

    var body: some View {
        if let agents {
            let store = agents.worktrees
            WorktreesLayout(trees: store.items, pulls: store.pulls, attentionOnly: attentionOnly, actions: actions(store))
                .widgetHeader {
                    Toggle(isOn: $attentionOnly) { Image(systemName: "exclamationmark.circle") }
                        .toggleStyle(.button).buttonStyle(.borderless)
                        .help("Only worktrees that need something")
                    if store.isScanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button { Task { await agents.refreshWorktrees() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Scan the worktrees now")
                    }
                }
                .overlay(alignment: .bottom) { if let error { Text(error).font(.caption).foregroundStyle(.red).padding(4) } }
                .sheet(item: $linking) { tree in LinkPullSheet(tree: tree, current: store.links[tree.path]) { link in
                    Task { await store.link(tree.path, to: link, host: host) }
                } }
        } else {
            StateView(.empty(title: "Agents is off", systemImage: "hammer", message: "Turn on the Agents plugin in Settings › Plugins."))
        }
    }

    private func actions(_ store: WorktreeStore) -> WorktreeActions {
        WorktreeActions(
            open: { tree, app in
                let url = URL(fileURLWithPath: tree.path)
                if let app, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) {
                    NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            },
            openPR: { pull in if let url = URL(string: pull.url) { NSWorkspace.shared.open(url) } },
            link: { linking = $0 },
            remove: { tree in
                Task {
                    do { try await store.remove(tree, host: host) } catch { self.error = error.localizedDescription }
                }
            })
    }
}

/// One layout per size: counts and the worst few (narrow), rows with badges (medium and up),
/// grouped by repository.
struct WorktreesLayout: View {
    let trees: [Worktree]
    let pulls: [String: WorktreePull]
    let attentionOnly: Bool
    let actions: WorktreeActions
    @Environment(\.widgetLayout) private var layout

    private var shown: [Worktree] {
        trees.filter { tree in
            !attentionOnly || WorktreeStatus.items(tree, pull: pulls[tree.path]).contains { $0.tone == .warning || $0.tone == .danger || $0.text == "Safe to remove" }
        }
    }

    var body: some View {
        let shown = shown
        if trees.isEmpty {
            StateView(.empty(title: "No worktrees yet", systemImage: "point.3.filled.connected.trianglepath.dotted",
                             message: "Dash scans the clones in your code folders (~/code, ~/Developer…, the Agents code folder and Knowledge's repositories) every 5 minutes. Scan now with ↻."))
        } else if layout.family == .narrow {
            narrow(shown)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Dictionary(grouping: shown, by: \.repo).sorted { $0.key < $1.key }, id: \.key) { repo, items in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(items.first?.slug ?? (repo as NSString).lastPathComponent, systemImage: "shippingbox")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(items) { tree in
                                WorktreeRow(tree: tree, pull: pulls[tree.path], detailed: layout.family == .wide || layout.family == .large, actions: actions)
                            }
                        }
                    }
                }
            }
        }
    }

    private func narrow(_ shown: [Worktree]) -> some View {
        let needing = trees.filter { tree in WorktreeStatus.items(tree, pull: pulls[tree.path]).contains { $0.tone == .warning || $0.tone == .danger } }
        let removable = trees.filter { WorktreeStatus.removable($0, pull: pulls[$0.path]) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(trees.filter { !$0.isMain }.count)").font(.title.weight(.semibold).monospacedDigit())
                Text("worktrees").foregroundStyle(.secondary)
            }
            if !needing.isEmpty { Label("\(needing.count) need something", systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.callout) }
            if !removable.isEmpty { Label("\(removable.count) safe to remove", systemImage: "trash").foregroundStyle(.green).font(.callout) }
            ForEach(needing.prefix(3)) { tree in Text(tree.branch ?? tree.name).font(.caption).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct WorktreeRow: View {
    let tree: Worktree
    let pull: WorktreePull?
    let detailed: Bool
    let actions: WorktreeActions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tree.isMain ? "house" : "arrow.triangle.branch").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tree.branch ?? "detached \(tree.head.prefix(7))").font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if let ticket = tree.ticket { Badge(ticket, tone: .accent) }
                    if tree.name != tree.branch { Text(tree.name).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                WrapBadges(items: WorktreeStatus.items(tree, pull: pull))
                if detailed, !tree.lastCommit.isEmpty {
                    Text("\(tree.lastCommit)\(tree.lastCommitAt.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Menu {
                Button("Show in Finder", systemImage: "folder") { actions.open(tree, nil) }
                Button("Open in Terminal", systemImage: "terminal") { actions.open(tree, "com.apple.Terminal") }
                Button("Open in Cursor", systemImage: "chevron.left.forwardslash.chevron.right") { actions.open(tree, "com.todesktop.230313mzl4w4u92") }
                Button("Copy Path", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tree.path, forType: .string)
                }
                Divider()
                if let pull { Button("Open \(pull.label)", systemImage: "arrow.up.right.square") { actions.openPR(pull) } }
                if !tree.isMain { Button("Link to a Pull Request…", systemImage: "link") { actions.link(tree) } }
                if WorktreeStatus.removable(tree, pull: pull) {
                    Divider()
                    Button("Remove Worktree…", systemImage: "trash", role: .destructive) { actions.remove(tree) }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
    }
}

/// Status badges that wrap to the next line.
struct WrapBadges: View {
    let items: [WorktreeStatus.Item]

    var body: some View {
        WrapLayout(spacing: 4) {
            ForEach(items, id: \.text) { item in Badge(item.text, tone: item.tone).help(item.help) }
        }
    }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// Links a worktree to a pull request by hand ("owner/name#123"), or unlinks it.
struct LinkPullSheet: View {
    let tree: Worktree
    let current: String?
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link \(tree.name) to a pull request").font(.headline)
            Text("When the branch name doesn't match the PR's. Stays in Dash.").font(.callout).foregroundStyle(.secondary)
            TextField("owner/name#123", text: $text).textFieldStyle(.roundedBorder)
            HStack {
                if current != nil { Button("Unlink", role: .destructive) { save(nil); dismiss() } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Link") { save(text.trimmingCharacters(in: .whitespaces)); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!WorktreeStore.isPullReference(text.trimmingCharacters(in: .whitespaces)))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { text = current ?? (tree.slug.map { $0 + "#" } ?? "") }
    }
}

/// The gallery's sample worktrees.
enum WorktreeSample {
    static func tree(_ name: String, branch: String?, main: Bool = false, changed: Int = 0, upstream: String? = nil, ahead: Int = 0, behind: Int = 0,
                     baseAhead: Int = 0, baseBehind: Int = 0, commit: String = "") -> Worktree {
        Worktree(path: "/code/billing-api/.worktrees/\(name)", repo: "/code/billing-api", slug: "acme/billing-api", branch: branch, head: "a1b2c3d4e5f6",
                 isMain: main, changed: changed, untracked: 0, upstream: upstream, ahead: ahead, behind: behind, base: "origin/main",
                 baseAhead: baseAhead, baseBehind: baseBehind, lastCommitAt: .now.addingTimeInterval(-7200), lastCommit: commit, scannedAt: .now)
    }

    static let trees = [
        tree("billing-api", branch: "main", main: true, upstream: "origin/main"),
        tree("KAN-12", branch: "KAN-12-retry", changed: 2, upstream: "origin/KAN-12-retry", ahead: 1, baseAhead: 3, baseBehind: 4, commit: "feat: retry the order fetch"),
        tree("KAN-7", branch: "KAN-7-cache", upstream: "origin/KAN-7-cache", baseAhead: 5, baseBehind: 930, commit: "feat: cache the lineups"),
        tree("KAN-3", branch: "KAN-3-flags", upstream: "origin/KAN-3-flags", baseAhead: 2, baseBehind: 12, commit: "fix: read the flag once"),
    ]

    static let pulls: [String: WorktreePull] = [
        "/code/billing-api/.worktrees/KAN-12": WorktreePull(repo: "acme/billing-api", number: 812, title: "Retry the order fetch", state: "open", url: ""),
        "/code/billing-api/.worktrees/KAN-3": WorktreePull(repo: "acme/billing-api", number: 790, title: "Read the flag once", state: "merged", url: ""),
    ]
}
