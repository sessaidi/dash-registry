import DashKit
import DashKitUI
import SwiftUI
import WorkspaceKit

/// The widget body: the feature's workspaces after "only mine" and the query bar, with selection,
/// actions and the workspace and create sheets.
struct WorkspaceList: View {
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

struct NodePoolBadge: View {
    let pool: NodePool

    var body: some View {
        Badge(pool.rawValue, tone: [.spot: .warning, .standard: .accent, .legacy: .info, .unknown: .danger][pool] ?? .neutral)
            .frame(width: 64)
    }
}
