import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// What the pods are a view of: the widget's context, namespace and filters, and the last sync.
struct PodsScope {
    var context: String?
    var namespace: String
    var allNamespaces: Bool
    var filters: [String] = []
    var lastSync: Date?
    var error: String?
}

/// What a pod row can do: pick it (select and open), open its details, copy kubectl commands.
struct PodActions {
    var pick: (PodSummary) -> Void = { _ in }
    var details: (PodSummary) -> Void = { _ in }
    /// The kubeconfig context for copied commands.
    var context: String?
}

/// The pods the widget shows, laid out for its size family:
/// - narrow: a verdict ("3 crash-looping"), the counts in one line, and the three most urgent pods;
/// - medium: the list, ready/age/node on one line, status and restarts as badges;
/// - wide: kubectl get pods as a table (namespace and node columns when there's room);
/// - large: a summary strip, the table, and the selected pod's detail or a breakdown by namespace/node.
/// The live widget and the gallery preview both render this, so it takes plain data.
struct PodsContent: View {
    let pods: [PodSummary]
    /// Pods before the filters and the query bar.
    let total: Int
    let warnings: [String: [String]]
    let scope: PodsScope
    var emptyTitle = "No pods"
    var actions = PodActions()
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if layout.family == .narrow {
                PodsCompactHeader(scope: scope, shown: pods.count, total: total)
            } else {
                PodsScopeHeader(scope: scope, shown: pods.count, total: total)
            }
            if pods.isEmpty {
                StateView(.empty(title: emptyTitle, systemImage: "checkmark.circle", message: "Namespace \(scope.namespace)"))
            } else {
                switch layout.family {
                case .narrow:
                    PodsNarrowView(pods: pods, warnings: warnings, actions: actions)
                case .wide:
                    PodTable(pods: pods, warnings: warnings, showNamespace: scope.allNamespaces, showNode: layout.size.width >= 820, actions: actions)
                case .large:
                    PodsLargeView(pods: pods, warnings: warnings, scope: scope, showNode: layout.size.width >= 1100, actions: actions)
                default:
                    PodsMediumView(pods: pods, warnings: warnings, allNamespaces: scope.allNamespaces, actions: actions)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Families

/// Narrow: the verdict, the counts on one line, and the three pods most in need of a look.
struct PodsNarrowView: View {
    let pods: [PodSummary]
    let warnings: [String: [String]]
    let actions: PodActions
    @Environment(\.podSelectedID) private var selectedID

    var body: some View {
        let counts = PodCounts(pods)
        let urgent = PodSummary.byUrgency(pods.filter { $0.tone == .danger || $0.tone == .warning })
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(counts.headlineTone)
                Text(counts.headline).font(.headline).lineLimit(1)
            }
            Text(counts.line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if !urgent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(urgent.prefix(3)) { pod in
                        HStack(spacing: 6) {
                            StatusDot(pod.tone, help: pod.status)
                            Text(pod.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 2)
                            Text(warnings[pod.id]?.first ?? pod.status).font(.caption2).foregroundStyle(pod.tone.color).lineLimit(1).fixedSize()
                        }
                        .padding(.vertical, 1)
                        .background(selectedID == pod.id ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 4))
                        .contentShape(.rect)
                        .onTapGesture { actions.pick(pod) }
                        .podContextMenu(pod, actions)
                    }
                }
                if urgent.count > 3 {
                    Text("+\(urgent.count - 3) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Medium: the list, one pod per row.
struct PodsMediumView: View {
    let pods: [PodSummary]
    let warnings: [String: [String]]
    let allNamespaces: Bool
    let actions: PodActions
    @Environment(\.podSelectedID) private var selectedID

    var body: some View {
        List(pods) { pod in
            PodRow(pod: pod, subtitle: subtitle(pod), warnings: warnings[pod.id] ?? [])
                .contentShape(.rect)
                .onTapGesture { actions.pick(pod) }
                .listRowBackground(selectedID == pod.id ? Color.accentColor.opacity(0.18) : Color.clear)
                .podContextMenu(pod, actions)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func subtitle(_ pod: PodSummary) -> String {
        [allNamespaces ? pod.namespace : nil, "\(pod.ready)/\(pod.total) ready", PodSummary.age(since: pod.created), pod.node]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// Large: counts across the top, then the table beside the selected pod or a breakdown.
struct PodsLargeView: View {
    let pods: [PodSummary]
    let warnings: [String: [String]]
    let scope: PodsScope
    let showNode: Bool
    let actions: PodActions
    @Environment(\.podSelectedID) private var selectedID

    var body: some View {
        let counts = PodCounts(pods)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                MetricView("\(counts.running)", label: "Running", tone: counts.running > 0 ? .success : .neutral)
                MetricView("\(counts.failing)", label: "Failing", tone: counts.failing > 0 ? .danger : .neutral)
                MetricView("\(counts.notReady)", label: "Not ready", tone: counts.notReady > 0 ? .warning : .neutral)
                MetricView("\(counts.restarts)", label: "Restarts", tone: counts.restarts > 0 ? .warning : .neutral)
            }
            HStack(alignment: .top, spacing: 16) {
                PodTable(pods: pods, warnings: warnings, showNamespace: scope.allNamespaces, showNode: showNode, actions: actions)
                Group {
                    if let pod = pods.first(where: { $0.id == selectedID }) {
                        PodSummaryPanel(pod: pod, warnings: warnings[pod.id] ?? [], actions: actions)
                    } else {
                        PodBreakdown(pods: pods, byNamespace: scope.allNamespaces)
                    }
                }
                .frame(width: 260)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

// MARK: - Headers

/// Context, namespace and filters as badges, the count and the last sync.
private struct PodsScopeHeader: View {
    let scope: PodsScope
    let shown: Int
    let total: Int

    var body: some View {
        HStack(spacing: 6) {
            if let context = scope.context {
                Badge(context, tone: .neutral, systemImage: "server.rack").lineLimit(1).truncationMode(.middle).frame(maxWidth: 260).help("Context")
            }
            Badge(scope.namespace, tone: .info, systemImage: "square.stack.3d.up").fixedSize().help("Namespace")
            if !scope.filters.isEmpty {
                Badge(scope.filters.count == 1 ? scope.filters[0] : "\(scope.filters.count) filters", tone: .warning, systemImage: "line.3.horizontal.decrease")
                    .help(scope.filters.joined(separator: " · "))
            }
            Text(shown == total ? "\(total) pods" : "\(shown) of \(total)").font(.caption).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 4)
            if let error = scope.error { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).help(error) }
            if let lastSync = scope.lastSync { RelativeTime(lastSync).font(.caption).foregroundStyle(.secondary).fixedSize() }
        }
    }
}

/// The same in one line of text, for narrow widgets.
private struct PodsCompactHeader: View {
    let scope: PodsScope
    let shown: Int
    let total: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(scope.namespace).foregroundStyle(.tint).lineLimit(1)
            Text("· " + (shown == total ? "\(total) pods" : "\(shown)/\(total)")).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            if !scope.filters.isEmpty { Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Tone.warning.color) }
            Spacer(minLength: 0)
            if let error = scope.error { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).help(error) }
        }
        .font(.caption)
        .help([scope.context, scope.namespace].compactMap { $0 }.joined(separator: " · ") + "\n" + scope.filters.joined(separator: " · "))
    }
}

// MARK: - Pieces

/// How many pods are in each state.
struct PodCounts {
    var running = 0, failing = 0, notReady = 0, completed = 0, crashLooping = 0, restarts = 0

    init(_ pods: [PodSummary]) {
        for pod in pods {
            switch pod.tone {
            case .success: running += 1
            case .danger: failing += 1
            case .warning: notReady += 1
            default: if pod.phase == "Succeeded" || pod.status == "Completed" { completed += 1 }
            }
            if pod.isCrashLooping { crashLooping += 1 }
            restarts += pod.restarts
        }
    }

    /// "3 crash-looping", "2 failing", "1 not ready" or "12 healthy".
    var headline: String {
        if crashLooping > 0, crashLooping == failing { return "\(crashLooping) crash-looping" }
        if failing > 0 { return "\(failing) failing" }
        if notReady > 0 { return "\(notReady) not ready" }
        return "\(running + completed) healthy"
    }

    var headlineTone: Tone { failing > 0 ? .danger : notReady > 0 ? .warning : .success }

    /// The rest of the counts: "9 running · 1 not ready · 2 done · ↻14".
    var line: String {
        // The headline already says the failing pods, or the not-ready ones when nothing fails.
        [running > 0 ? "\(running) running" : nil, notReady > 0 && failing > 0 ? "\(notReady) not ready" : nil,
         completed > 0 ? "\(completed) done" : nil,
         restarts > 0 ? "↻\(restarts)" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

extension PodSummary {
    /// Failing before not ready, then most restarted.
    static func byUrgency(_ pods: [PodSummary]) -> [PodSummary] {
        pods.sorted { a, b in
            let rank = { (pod: PodSummary) in pod.tone == .danger ? 0 : pod.tone == .warning ? 1 : 2 }
            return (rank(a), -a.restarts, a.name) < (rank(b), -b.restarts, b.name)
        }
    }
}

/// One pod: the name on one line (cut in the middle, where hashes are), details below, and the
/// status, restarts and first warning as badges.
private struct PodRow: View {
    let pod: PodSummary
    let subtitle: String
    let warnings: [String]

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(pod.tone, help: pod.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(pod.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .help(pod.name + "\n" + subtitle)
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if let warning = warnings.first {
                    Badge(warning, tone: .warning, systemImage: "exclamationmark.triangle").help(warnings.joined(separator: ", "))
                }
                if pod.restarts > 0 { Badge("\(pod.restarts)", tone: pod.isCrashLooping ? .danger : .warning, systemImage: "arrow.clockwise") }
                Badge(pod.status, tone: pod.tone)
            }
            .fixedSize()
        }
        .padding(.vertical, 2)
    }
}

/// kubectl get pods as a table. The header and the rows share one set of column widths and
/// margins. Click a row for the pod's details.
private struct PodTable: View {
    let pods: [PodSummary]
    let warnings: [String: [String]]
    let showNamespace: Bool
    let showNode: Bool
    let actions: PodActions
    @State private var hovered: String?
    @Environment(\.podSelectedID) private var selectedID

    var body: some View {
        VStack(spacing: 0) {
            // The header's dot slot is empty but sized: a bare Color.clear would grow the row.
            columns(dot: AnyView(Color.clear.frame(width: 8, height: 8)), name: Text("Name"), namespace: Text("Namespace"), ready: Text("Ready"),
                    status: AnyView(Text("Status")), restarts: Text("Restarts"), age: Text("Age"), node: Text("Node"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.vertical, 5)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pods) { pod in
                        columns(dot: AnyView(StatusDot(pod.tone, help: pod.status)),
                                name: Text(pod.name).font(.callout.monospaced()),
                                namespace: Text(pod.namespace),
                                ready: Text("\(pod.ready)/\(pod.total)").monospacedDigit(),
                                status: AnyView(HStack(spacing: 4) {
                                    Text(pod.status).foregroundStyle(pod.tone == .success ? Color.primary : pod.tone.color)
                                    if let warning = warnings[pod.id]?.first {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).help(warning)
                                    }
                                }),
                                restarts: Text("\(pod.restarts)").monospacedDigit().foregroundStyle(pod.restarts > 0 ? Tone.warning.color : .primary),
                                age: Text(PodSummary.age(since: pod.created)).monospacedDigit(),
                                node: Text(pod.node ?? "—").foregroundStyle(.secondary))
                            .font(.callout)
                            .padding(.vertical, 6)
                            .background(selectedID == pod.id ? AnyShapeStyle(.tint.opacity(0.18)) : hovered == pod.id ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                            .contentShape(.rect)
                            .onHover { hovered = $0 ? pod.id : (hovered == pod.id ? nil : hovered) }
                            .onTapGesture { actions.pick(pod) }
                            .podContextMenu(pod, actions)
                            .help(pod.name)
                        Divider().opacity(0.5)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    /// One line of the table, header or pod: fixed widths except the name, which takes the rest.
    private func columns(dot: AnyView, name: Text, namespace: Text, ready: Text, status: AnyView, restarts: Text, age: Text, node: Text) -> some View {
        HStack(spacing: 12) {
            dot.frame(width: 10)
            // The name gets the room first; the node shares what's left.
            name.lineLimit(1).truncationMode(.middle).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            if showNamespace { namespace.lineLimit(1).truncationMode(.tail).frame(width: 110, alignment: .leading) }
            ready.frame(width: 44, alignment: .leading)
            status.lineLimit(1).frame(width: 136, alignment: .leading)
            restarts.frame(width: 56, alignment: .trailing)
            age.frame(width: 40, alignment: .trailing)
            if showNode { node.lineLimit(1).truncationMode(.middle).frame(minWidth: 100, maxWidth: 240, alignment: .leading) }
        }
        .padding(.horizontal, 8)
    }
}

/// The selected pod at a glance, beside the table; Details opens the full sheet.
private struct PodSummaryPanel: View {
    let pod: PodSummary
    let warnings: [String]
    let actions: PodActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pod.name).font(.callout.monospaced().weight(.semibold)).lineLimit(2).truncationMode(.middle)
            HStack(spacing: 4) {
                Badge(pod.status, tone: pod.tone)
                if pod.restarts > 0 { Badge("\(pod.restarts)", tone: pod.isCrashLooping ? .danger : .warning, systemImage: "arrow.clockwise") }
            }
            Group {
                LabeledContent("Namespace", value: pod.namespace)
                LabeledContent("Ready", value: "\(pod.ready)/\(pod.total)")
                LabeledContent("Age", value: PodSummary.age(since: pod.created))
                if let node = pod.node { LabeledContent("Node", value: node) }
                if let owner = pod.owner { LabeledContent("Owner", value: owner) }
                if let ip = pod.podIP { LabeledContent("IP", value: ip) }
            }
            .font(.caption)
            if !warnings.isEmpty {
                Label(warnings.joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Tone.warning.color).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Details…") { actions.details(pod) }.controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }
}

/// Healthy and failing pods per namespace (all namespaces) or per node.
private struct PodBreakdown: View {
    let pods: [PodSummary]
    let byNamespace: Bool

    var body: some View {
        let groups = Dictionary(grouping: pods) { byNamespace ? $0.namespace : ($0.node ?? "unscheduled") }
            .map { (name: $0.key, counts: PodCounts($0.value), total: $0.value.count) }
            .sorted { ($0.counts.failing + $0.counts.notReady, $0.total, $1.name) > ($1.counts.failing + $1.counts.notReady, $1.total, $0.name) }
        VStack(alignment: .leading, spacing: 8) {
            Text(byNamespace ? "By namespace" : "By node").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(group.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                if group.counts.failing > 0 { Badge("\(group.counts.failing)", tone: .danger) }
                                if group.counts.notReady > 0 { Badge("\(group.counts.notReady)", tone: .warning) }
                                Text("\(group.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            HealthBar(counts: group.counts, total: group.total)
                        }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }
}

/// A thin bar split into running, not ready, failing and done.
private struct HealthBar: View {
    let counts: PodCounts
    let total: Int

    var body: some View {
        GeometryReader { geometry in
            let unit = geometry.size.width / CGFloat(max(1, total))
            HStack(spacing: 0) {
                Tone.success.color.frame(width: unit * CGFloat(counts.running))
                Tone.warning.color.frame(width: unit * CGFloat(counts.notReady))
                Tone.danger.color.frame(width: unit * CGFloat(counts.failing))
                Color.secondary.opacity(0.4).frame(width: unit * CGFloat(max(0, total - counts.running - counts.notReady - counts.failing)))
            }
            .clipShape(.capsule)
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

// MARK: - Context menu

extension View {
    /// Details and copy commands for a pod row.
    func podContextMenu(_ pod: PodSummary, _ actions: PodActions) -> some View {
        contextMenu {
            Button("Details") { actions.details(pod) }
            Button("Copy Name") { copyToPasteboard(pod.name) }
            Button("Copy kubectl logs") { copyToPasteboard(PodCommands.logs(pod, context: actions.context)) }
            Button("Copy kubectl exec") { copyToPasteboard(PodCommands.exec(pod, context: actions.context)) }
        }
    }
}

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension EnvironmentValues {
    /// The pod picked in the widget, drawn as selected.
    @Entry var podSelectedID: String? = nil
}
