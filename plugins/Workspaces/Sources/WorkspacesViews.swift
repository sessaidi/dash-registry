import AppKit
import DashKit
import DashKitUI
import Foundation
import SwiftUI
import WorkspaceKit

// MARK: - Widget

struct WorkspacesWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var onlyMine: Bool
    }

    static let kind = "workspaces.list"
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let displayName = "Workspaces"
    static let summary = "Backend workspaces on GKE: owner, node pool, last deploy, persist flag. Open one for pods and actions."
    static let systemImage = "shippingbox"
    static let defaultConfig = Config(onlyMine: true)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["onlyMine": ["type": "boolean", "description": "Only workspaces deployed by the user."]],
    ]

    static let queryFields = WorkspaceItem.queryFields
    static let actions = [
        WidgetAction(name: "select", description: "Select a workspace by name; linked widgets follow the selection. Temporary.",
                     properties: ["name": JSONSchema.string("Workspace name.")], required: ["name"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected workspace."),
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        WorkspaceList(feature: context.host.ext(WorkspacesFeature.self), host: context.host, onlyMine: config.wrappedValue.onlyMine,
                      query: context.query(fields: WorkspaceItem.queryFields), queryText: context.queryText)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Only mine", isOn: config.onlyMine)
    }

    /// Sample workspaces, no cluster: the gallery and Settings render this.
    static func preview(config: Config) -> some View {
        let items = WorkspaceItem.samples.filter { !config.onlyMine || $0.deployedBy == WorkspaceItem.sampleUser }
        return WorkspaceListContent(scope: "dev/us", items: items, busy: ["checkout-flow"], isLoading: false, error: nil)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let feature = context.host.ext(WorkspacesFeature.self) else { return [] }
        return .array(feature.visible(onlyMine: config.onlyMine).map(WorkspacesFeature.json))
    }
}

/// What a row shows. Built from a WorkspaceKit `Workspace`, or by hand for previews
/// (`Workspace` has no public initializer).
extension WorkspaceItem {
    /// A workspace by exact name, else the only one whose name contains the text.
    static func find(_ text: String, in items: [WorkspaceItem]) -> WorkspaceItem? {
        let wanted = text.lowercased()
        if let exact = items.first(where: { $0.name.lowercased() == wanted }) { return exact }
        let hits = items.filter { $0.name.lowercased().contains(wanted) }
        return wanted.isEmpty || hits.count != 1 ? nil : hits[0]
    }
}

struct WorkspaceItem: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let deployedBy: String
    let gitBranch: String?
    /// Last deploy, else creation.
    let lastDeploy: Date?
    let persist: Bool
    let nodePool: NodePool
    /// Why `clean` would delete it; nil to keep (always nil when persisted).
    let cleanReason: String?

    init(name: String, deployedBy: String, gitBranch: String?, lastDeploy: Date?, persist: Bool, nodePool: NodePool, cleanReason: String?) {
        self.name = name
        self.deployedBy = deployedBy
        self.gitBranch = gitBranch
        self.lastDeploy = lastDeploy
        self.persist = persist
        self.nodePool = nodePool
        self.cleanReason = persist ? nil : cleanReason
    }

    init(_ workspace: Workspace, now: Date = Date()) {
        self.init(
            name: workspace.name, deployedBy: workspace.deployedBy, gitBranch: workspace.gitBranch,
            lastDeploy: workspace.deployedAt ?? workspace.createdAt, persist: workspace.persist,
            nodePool: workspace.nodePool, cleanReason: workspace.cleanReason(now: now))
    }

    var subtitle: String {
        [deployedBy, gitBranch, lastDeploy.map { "deployed \($0.relative)" }].compactMap { $0 }.joined(separator: " · ")
    }

    static let sampleUser = "sadik"

    static var samples: [WorkspaceItem] {
        let now = Date()
        return [
            WorkspaceItem(name: "checkout-flow", deployedBy: sampleUser, gitBranch: "feat/checkout", lastDeploy: now.addingTimeInterval(-3_600),
                          persist: false, nodePool: .spot, cleanReason: nil),
            WorkspaceItem(name: "papi-perf", deployedBy: sampleUser, gitBranch: "main", lastDeploy: now.addingTimeInterval(-86_400 * 2),
                          persist: true, nodePool: .standard, cleanReason: nil),
            WorkspaceItem(name: "old-search", deployedBy: sampleUser, gitBranch: "search-v2", lastDeploy: now.addingTimeInterval(-86_400 * 12),
                          persist: false, nodePool: .legacy, cleanReason: "not deployed for over a week"),
            WorkspaceItem(name: "epg-refresh", deployedBy: "jrivera", gitBranch: "LAF-1234", lastDeploy: now.addingTimeInterval(-600),
                          persist: false, nodePool: .spot, cleanReason: nil),
        ]
    }
}

private struct WorkspaceList: View {
    let feature: WorkspacesFeature?
    let host: any ExtensionContext
    let onlyMine: Bool
    /// The widget's DashQL query (its query bar), applied after "only mine".
    let query: WidgetQuery?
    let queryText: String
    /// The workspace whose sheet is open.
    @State private var selected: String?
    /// The workspace the user picked: highlighted and published for linked widgets until another
    /// is picked or it's clicked again.
    @State private var picked: String?
    @State private var creating = false
    @State private var queryNames: [String]?

    var body: some View {
        if let feature {
            let all = feature.visible(onlyMine: onlyMine).map { WorkspaceItem($0) }
            let items = QueryRows.ordered(all, by: queryNames)
            VStack(alignment: .leading, spacing: 2) {
                QueryCount(shown: items.count, total: all.count, query: queryText)
                WorkspaceListContent(
                    scope: "\(feature.env.rawValue)/\(feature.region.rawValue)",
                    items: items,
                    busy: feature.busy, isLoading: feature.isLoading, error: feature.lastError,
                    selectedName: picked,
                    refresh: { Task { await feature.refresh() } },
                    select: { name in
                        // Clicking selects and opens; clicking the selected one again unselects it.
                        if picked == name { picked = nil } else { picked = name; selected = name }
                    },
                    create: { creating = true })
                    .sheet(item: Binding(get: { selected.map(SheetID.init) }, set: { selected = $0?.id })) {
                        WorkspaceSheet(name: $0.id, feature: feature, host: host)
                    }
                    .sheet(isPresented: $creating) { CreateWorkspaceSheet(feature: feature) }
            }
            .task(id: QueryRows.key(queryText, all, row: \.queryRow)) {
                queryNames = await QueryRows.ids(query, all, row: \.queryRow)
            }
            .onExitCommand { picked = nil }
            .reportsSelection(picked.flatMap { name in all.first { $0.name == name }?.queryRow })
            .handlesWidgetActions { name, input in
                switch name {
                case "select":
                    let wanted = input["name"]?.string ?? ""
                    guard let item = WorkspaceItem.find(wanted, in: items) else { throw ToolError("No shown workspace “\(wanted)”.") }
                    picked = item.name
                    return ["selected": .string(item.name)]
                case "clear_selection":
                    picked = nil
                    return "cleared"
                default:
                    throw ToolError("Unknown action \(name).")
                }
            }
        } else {
            StateView(.failed(message: "The Workspaces feature isn't loaded."))
        }
    }

    struct SheetID: Identifiable { let id: String }
}

/// The list itself, fed plain values so previews can draw it from samples.
struct WorkspaceListContent: View {
    let scope: String
    let items: [WorkspaceItem]
    let busy: Set<String>
    let isLoading: Bool
    let error: String?
    var selectedName: String? = nil
    var refresh: (() -> Void)?
    var select: ((String) -> Void)?
    var create: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scope).font(.caption.monospaced()).foregroundStyle(.secondary)
                if isLoading { ProgressView().controlSize(.mini) }
                Spacer()
                if let create {
                    Button("New Workspace", systemImage: "plus") { create() }
                        .labelStyle(.iconOnly).buttonStyle(.borderless).help("Create a workspace from a profile, linked to a worktree")
                }
                Button("Refresh", systemImage: "arrow.clockwise") { refresh?() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            if let error, items.isEmpty {
                ContentUnavailableView("Couldn't load workspaces", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(isLoading ? "Loading…" : "No workspaces", systemImage: "shippingbox")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    WorkspaceRow(item: item, busy: busy.contains(item.name))
                        .contentShape(.rect)
                        .onTapGesture { select?(item.name) }
                        .listRowBackground(selectedName == item.name ? Color.accentColor.opacity(0.18) : Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct WorkspaceRow: View {
    let item: WorkspaceItem
    let busy: Bool

    var body: some View {
        HStack(spacing: 8) {
            if busy { ProgressView().controlSize(.small) } else { NodePoolBadge(pool: item.nodePool) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(item.name).font(.callout.monospaced())
                    if item.persist { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.blue).help("Persisted: never cleaned") }
                }
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let reason = item.cleanReason {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange).help(reason)
            }
        }
    }
}

private struct NodePoolBadge: View {
    let pool: NodePool

    var body: some View {
        Badge(pool.rawValue, tone: [.spot: .warning, .standard: .accent, .legacy: .info, .unknown: .danger][pool] ?? .neutral)
            .frame(width: 64)
    }
}

// MARK: - Workspace sheet

private struct WorkspaceSheet: View {
    let name: String
    let feature: WorkspacesFeature
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @State private var status: WorkspaceStatus?
    @State private var error: String?
    @State private var working = false
    @State private var tab = WorkspaceTab.overview

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(name).font(.title3.bold().monospaced())
                if let workspace = status?.workspace { NodePoolBadge(pool: workspace.nodePool) }
                Spacer()
                if let url = status.flatMap({ URL(string: "https://\($0.workspace.url)") }) { Link("Open", destination: url) }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("View", selection: $tab) { ForEach(WorkspaceTab.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            switch tab {
            case .train: WorkspaceTrainView(name: name, feature: feature)
            case .logs: WorkspaceLogsView(name: name, feature: feature)
            case .cloud: WorkspaceCloudLogsView(name: name, feature: feature)
            case .diagnose: WorkspaceDiagnoseView(name: name, feature: feature)
            case .config: WorkspaceConfigView(name: name, feature: feature)
            case .commands: WorkspaceCommandsView(name: name, feature: feature)
            case .overview:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let status {
                        Text("Deployed by \(status.workspace.deployedBy)\(status.workspace.gitBranch.map { " from \($0)" } ?? "")")
                            .foregroundStyle(.secondary)
                        Text("Deployments").font(.headline)
                        ForEach(status.deployments, id: \.name) { deployment in
                            HStack {
                                Image(systemName: deployment.ready >= deployment.desired ? "checkmark.circle.fill" : "hourglass")
                                    .foregroundStyle(deployment.ready >= deployment.desired ? .green : .orange)
                                Text(deployment.name).font(.callout.monospaced())
                                Text("\(deployment.ready)/\(deployment.desired)").foregroundStyle(.secondary)
                                Spacer()
                                Text(deployment.images.first?.split(separator: ":").last.map(String.init) ?? "").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        let problems = status.pods.filter { $0.problem != nil || !$0.ready }
                        if !problems.isEmpty {
                            Text("Pods needing attention").font(.headline)
                            ForEach(problems, id: \.name) { pod in
                                Label("\(pod.name): \(pod.problem ?? pod.phase) · \(pod.restarts) restarts", systemImage: "exclamationmark.triangle")
                                    .font(.callout).foregroundStyle(.red)
                            }
                        }
                        if !status.hostnames.isEmpty {
                            Text("Hostnames").font(.headline)
                            ForEach(status.hostnames, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                        }
                    } else if error == nil {
                        ProgressView()
                    }
                    linkSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if let workspace = status?.workspace {
                    Button(workspace.persist ? "Stop Persisting" : "Persist") { run { try await feature.setPersist(name, !workspace.persist) } }
                }
                if feature.links[name] != nil {
                    Button("Deploy Worktree", systemImage: "arrow.up.circle") { run { try await feature.deployWorktree(name) } }
                        .help("Build the linked worktree and deploy it (up-toolbox workspace run)")
                }
                Button("Ask Claude", systemImage: "sparkles") {
                    host.askClaude("Check workspace \(name): read its status and tell me if anything is wrong.")
                    dismiss()
                }
                Spacer()
                Button("Delete…", role: .destructive) { run { try await feature.delete(name); dismiss() } }
            }
            .disabled(working)
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 600)
        .task { await load() }
    }

    private func load() async {
        do { status = try await feature.client().status(name) } catch { self.error = WorkspacesFeature.describe(error) }
    }

    /// The worktree this workspace deploys from.
    @ViewBuilder private var linkSection: some View {
        Text("Code").font(.headline)
        if let link = feature.links[name] {
            Label((link.worktree as NSString).abbreviatingWithTildeInPath, systemImage: "arrow.triangle.branch").font(.callout.monospaced())
            if link.service != link.worktree { Text("builds \(URL(fileURLWithPath: link.service).lastPathComponent)").font(.caption).foregroundStyle(.secondary) }
        } else {
            Text("Not linked to a worktree.").foregroundStyle(.secondary)
        }
        Button(feature.links[name] == nil ? "Link a Worktree…" : "Change Worktree…") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.directoryURL = URL(fileURLWithPath: (("~/Codes") as NSString).expandingTildeInPath)
            if panel.runModal() == .OK, let url = panel.url { feature.link(name, worktree: url.path) }
        }
        if working { ProgressView("Working… see Commands for each step").controlSize(.small) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        working = true
        error = nil
        Task {
            do { try await action(); await load() } catch { self.error = WorkspacesFeature.describe(error) }
            working = false
        }
    }
}

// MARK: - Settings

struct WorkspacesSettings: View {
    @Bindable var feature: WorkspacesFeature
    @State private var candidates: [(workspace: Workspace, reason: String)] = []
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Picker("Environment", selection: $feature.env) {
                    ForEach(WorkspaceEnvironment.allCases, id: \.self) { Text("\($0.rawValue) (\($0.project))").tag($0) }
                }
                Picker("Region", selection: $feature.region) {
                    ForEach(WorkspaceRegion.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Your deployed_by name", text: $feature.username)
                Stepper("Refresh every \(feature.pollMinutes) min", value: $feature.pollMinutes, in: 1...30)
            } header: {
                Text("Uses the Google Cloud integration")
            } footer: {
                Text(feature.lastError ?? "Talks to the GKE and Kubernetes APIs directly; kubectl and up-toolbox aren't used.")
                    .foregroundStyle(feature.lastError == nil ? Color.secondary : .red)
            }
            Section("Profiles") {
                ProfilesEditor(feature: feature)
            }
            Section("When a PR is merged") {
                Toggle("Delete my workspace deployed from its branch (unless persisted)", isOn: $feature.removeWhenMerged)
            }
            Section("Clean") {
                ForEach(candidates, id: \.workspace.name) { item in
                    LabeledContent(item.workspace.name, value: item.reason)
                }
                if let message { Text(message).foregroundStyle(.secondary) }
                HStack {
                    Button("Find Stale Workspaces") {
                        Task {
                            do { candidates = try await feature.client().cleanCandidates(); message = candidates.isEmpty ? "Nothing to clean." : nil } catch { message = WorkspacesFeature.describe(error) }
                        }
                    }
                    Spacer()
                    Button("Delete \(candidates.count)…", role: .destructive) {
                        Task {
                            let names = candidates.map(\.workspace.name)
                            for name in names { try? await feature.delete(name) }
                            candidates = []
                        }
                    }
                    .disabled(candidates.isEmpty)
                }
            }
        }
    }
}
