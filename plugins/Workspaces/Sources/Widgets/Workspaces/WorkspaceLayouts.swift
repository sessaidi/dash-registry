import DashKit
import DashKitUI
import SwiftUI
import WorkspaceKit

// The Workspaces widget, one layout per size family. Each takes plain values, so the gallery
// draws them from samples.

/// What a workspace needs attention for, most urgent first.
enum WorkspaceState: Int, Comparable {
    /// An operation (deploy, clean, persist…) is running on it.
    case busy
    /// `clean` would delete it.
    case cleanable
    case active
    /// Never cleaned.
    case persisted

    init(_ item: WorkspaceItem, busy: Set<String>) {
        if busy.contains(item.name) { self = .busy }
        else if item.cleanReason != nil { self = .cleanable }
        else if item.persist { self = .persisted }
        else { self = .active }
    }

    var tone: Tone {
        switch self {
        case .busy: .info
        case .cleanable: .warning
        case .active: .success
        case .persisted: .accent
        }
    }

    var title: String {
        switch self {
        case .busy: "Working"
        case .cleanable: "To clean"
        case .active: "Active"
        case .persisted: "Persisted"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension WorkspaceItem {
    /// The workspaces to show first in a glance: busy, then about to be cleaned, then the most
    /// recently deployed.
    static func mostImportant(_ items: [WorkspaceItem], busy: Set<String>, limit: Int = 3) -> [WorkspaceItem] {
        // Busy and cleanable first; active and persisted ones only by how recent they are.
        func urgency(_ item: WorkspaceItem) -> Int { min(WorkspaceState(item, busy: busy).rawValue, WorkspaceState.active.rawValue) }
        return Array(items.sorted { lhs, rhs in
            urgency(lhs) != urgency(rhs) ? urgency(lhs) < urgency(rhs) : (lhs.lastDeploy ?? .distantPast) > (rhs.lastDeploy ?? .distantPast)
        }.prefix(limit))
    }

    /// The glance's headline and the line under it: "9 workspaces", "1 working · 2 to clean".
    static func headline(_ items: [WorkspaceItem], busy: Set<String>) -> (title: String, detail: String) {
        let states = items.map { WorkspaceState($0, busy: busy) }
        let counts = [WorkspaceState.busy, .cleanable, .persisted].compactMap { state -> String? in
            let count = states.filter { $0 == state }.count
            return count == 0 ? nil : "\(count) \(state.title.lowercased())"
        }
        return ("\(items.count) workspace\(items.count == 1 ? "" : "s")", counts.isEmpty ? "All active" : counts.joined(separator: " · "))
    }
}

// MARK: Narrow

/// A headline and the three workspaces that matter most.
struct WorkspaceGlance: View {
    let items: [WorkspaceItem]
    let busy: Set<String>
    let selectedName: String?
    let select: ((String) -> Void)?

    var body: some View {
        let headline = WorkspaceItem.headline(items, busy: busy)
        let top = WorkspaceItem.mostImportant(items, busy: busy)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline.title).font(.title3.weight(.semibold))
                Text(headline.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Divider()
            ForEach(top) { item in
                let state = WorkspaceState(item, busy: busy)
                ItemRow(item.name, subtitle: item.lastDeploy.map { "deployed \($0.relative)" } ?? item.deployedBy, monospacedTitle: true) {
                    StatusDot(state.tone, help: item.cleanReason ?? state.title)
                } trailing: {
                    if state == .busy { ProgressView().controlSize(.mini) }
                }
                .selectableRow(selectedName == item.name) { select?(item.name) }
            }
            if items.count > top.count {
                Text("\(items.count - top.count) more").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Medium

/// Every workspace as a row: pool, name, owner, branch and last deploy.
struct WorkspaceRows: View {
    let items: [WorkspaceItem]
    let busy: Set<String>
    let selectedName: String?
    let select: ((String) -> Void)?

    var body: some View {
        List(items) { item in
            let state = WorkspaceState(item, busy: busy)
            ItemRow(item.name, subtitle: item.subtitle, monospacedTitle: true) {
                NodePoolBadge(pool: item.nodePool)
            } trailing: {
                if state == .busy { ProgressView().controlSize(.small) }
                WorkspaceStateIcons(item: item)
            }
            .onTapGesture { select?(item.name) }
            .listRowBackground(selectedName == item.name ? Color.accentColor.opacity(0.18) : Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
}

/// Lock for persisted, clock for about to be cleaned.
private struct WorkspaceStateIcons: View {
    let item: WorkspaceItem

    var body: some View {
        HStack(spacing: 4) {
            if item.persist { Image(systemName: "lock.fill").foregroundStyle(Tone.info.color).help("Persisted: never cleaned") }
            if let reason = item.cleanReason { Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Tone.warning.color).help(reason) }
        }
        .font(.caption)
    }
}

// MARK: Wide

/// A table with real columns: name, owner, branch, pool, last deploy, state.
struct WorkspaceTable: View {
    let items: [WorkspaceItem]
    let busy: Set<String>
    let selectedName: String?
    let select: ((String) -> Void)?

    var body: some View {
        Table(items, selection: Binding(
            get: { selectedName },
            set: { name in
                // A click picks (and opens) a row; clicking off the selection unpicks it.
                if let name { select?(name) } else if let selectedName { select?(selectedName) }
            })) {
            TableColumn("Name") { item in
                HStack(spacing: 4) {
                    Text(item.name).font(.callout.monospaced())
                    if item.persist { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Tone.info.color).help("Persisted: never cleaned") }
                }
            }
            .width(min: 90, ideal: 110)
            TableColumn("Owner", value: \.deployedBy)
                .width(min: 50, ideal: 64)
            TableColumn("Branch") { item in
                Text(item.gitBranch ?? "—").font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 60, ideal: 96)
            TableColumn("Pool") { item in Badge(item.nodePool.rawValue, tone: item.nodePool.tone) }
                .width(min: 64, ideal: 72)
            TableColumn("Last deploy") { item in
                if let date = item.lastDeploy { RelativeTime(date).foregroundStyle(.secondary) } else { Text("—").foregroundStyle(.tertiary) }
            }
            .width(min: 60, ideal: 80)
            TableColumn("State") { item in
                let state = WorkspaceState(item, busy: busy)
                HStack(spacing: 6) {
                    if state == .busy { ProgressView().controlSize(.mini) } else { StatusDot(state.tone) }
                    Text(state.title)
                }
                .help(item.cleanReason ?? state.title)
            }
            .width(min: 84, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
    }
}

// MARK: Large

/// Beside the table: totals, the split by node pool and owner, and the picked workspace (else
/// what `clean` would delete).
struct WorkspaceSummaryPanel: View {
    let items: [WorkspaceItem]
    let busy: Set<String>
    let selected: WorkspaceItem?

    var body: some View {
        let headline = WorkspaceItem.headline(items, busy: busy)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    MetricView("\(items.count)", label: headline.title.replacingOccurrences(of: "\(items.count) ", with: ""))
                    Text(headline.detail).font(.caption).foregroundStyle(.secondary)
                }
                section("Node pools") {
                    ForEach(pools, id: \.pool) { entry in
                        breakdownRow(count: entry.count, tone: entry.pool.tone) { Badge(entry.pool.rawValue, tone: entry.pool.tone) }
                    }
                }
                section("Owners") {
                    ForEach(owners, id: \.owner) { entry in
                        breakdownRow(count: entry.count, tone: .neutral) { Text(entry.owner).font(.callout) }
                    }
                }
                if let selected {
                    section("Selected") { WorkspaceDetail(item: selected, state: WorkspaceState(selected, busy: busy)) }
                } else {
                    let cleanable = items.filter { $0.cleanReason != nil }
                    section("To clean") {
                        if cleanable.isEmpty {
                            Text("Nothing: every workspace was deployed recently or is persisted.").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(cleanable) { item in
                            ItemRow(item.name, subtitle: item.cleanReason, monospacedTitle: true) { StatusDot(.warning) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var pools: [(pool: NodePool, count: Int)] {
        Dictionary(grouping: items, by: \.nodePool).map { ($0.key, $0.value.count) }.sorted { $0.count > $1.count }
    }

    private var owners: [(owner: String, count: Int)] {
        Array(Dictionary(grouping: items, by: \.deployedBy).map { ($0.key, $0.value.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.owner < $1.owner }.prefix(5))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    private func breakdownRow<Label: View>(count: Int, tone: Tone, @ViewBuilder label: () -> Label) -> some View {
        HStack(spacing: 8) {
            label()
            ProgressView(value: Double(count), total: Double(max(items.count, 1))).tint(tone == .neutral ? Color.accentColor : tone.color)
            Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// One workspace's facts, for the large layout's panel.
private struct WorkspaceDetail: View {
    let item: WorkspaceItem
    let state: WorkspaceState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusDot(state.tone)
                Text(item.name).font(.callout.monospaced().weight(.semibold))
                Badge(state.title, tone: state.tone)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                row("Owner", item.deployedBy)
                row("Branch", item.gitBranch ?? "—")
                row("Pool", item.nodePool.rawValue)
                row("Deployed", item.lastDeploy?.relative ?? "never")
                if let reason = item.cleanReason { row("Cleaned", reason) }
            }
            .font(.caption)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1)
        }
    }
}

extension NodePool {
    var tone: Tone {
        switch self {
        case .spot: .warning
        case .standard: .accent
        case .legacy: .info
        case .unknown: .danger
        }
    }
}

extension View {
    /// A tappable row with the selection's tint behind it.
    func selectableRow(_ selected: Bool, action: @escaping () -> Void) -> some View {
        padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onTapGesture(perform: action)
    }
}
