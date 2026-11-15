import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// The Pods widget: observes `PodsFeature.browsing` (refreshed on the widget's own interval),
/// applies Dashii's temporary changes and the query bar, and publishes the selection.
struct PodsWidgetView: View {
    let feature: PodsFeature?
    let host: any ExtensionContext
    /// The widget's saved settings.
    @Binding var settings: PodsWidget.Config
    /// The widget's DashQL query (its query bar), applied after the settings' filters.
    let query: WidgetQuery?
    let queryText: String
    /// The pod whose detail sheet is open.
    @State private var opened: PodSummary?
    /// The pod the user picked: highlighted and published for linked widgets until another is
    /// picked or it's clicked again.
    @State private var selectedID: String?
    /// What Dashii's actions changed for now (namespace, context, filters); the saved settings
    /// stay, and this resets when they change.
    @State private var override: PodsWidget.Config?
    @State private var queryIDs: [String]?

    /// The settings with Dashii's temporary changes on top: what the widget shows.
    private var config: PodsWidget.Config { override ?? settings }
    /// The widget's size family, from the dashboard: each gets its own layout.
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        main
            .handlesWidgetActions { name, input in
                if name == "clear_selection" {
                    selectedID = nil
                    return "cleared"
                }
                if name == "clear_filters" {
                    override = nil
                    return "cleared"
                }
                // Actions change what's shown for now, never the saved settings.
                var view = config
                let result = try PodsWidgetActions.perform(name, input, config: &view, pods: visiblePods)
                override = view == settings ? nil : view
                if let pod = result.select {
                    selectedID = pod.id
                    opened = pod
                }
                return result.reply
            }
            .onChange(of: settings) { override = nil }
            .onExitCommand { selectedID = nil }
            .reportsSelection(selectedPod.map(row))
            .reportsWidgetState(PodsWidgetActions.state(config: config, pods: visiblePods, total: browse?.pods.count ?? 0,
                                                        namespace: feature.map(namespaceLabel) ?? "", selected: opened)
                .merging(["selected": selectedPod.map { .string($0.id) } ?? .null, "temporary_changes": .bool(override != nil)]))
            .task(id: QueryRows.key(queryText, filteredPods, row: row)) {
                queryIDs = await QueryRows.ids(query, filteredPods, row: row)
            }
    }

    private var browse: PodsFeature.Browse? { feature?.browsing[config.browseKey] }

    /// The pods the settings' filters keep, sorted.
    private var filteredPods: [PodSummary] {
        let browse = browse
        return PodSummary.sorted((browse?.pods ?? []).filter { config.query.matches($0, warnings: browse?.warnings[$0.id] ?? []) }, by: config.podSort)
    }

    /// The pods the widget lists: the settings' filters, then the DashQL query.
    private var visiblePods: [PodSummary] { QueryRows.ordered(filteredPods, by: queryIDs) }

    private var selectedPod: PodSummary? { selectedID.flatMap { id in browse?.pods.first { $0.id == id } } }

    /// Clicking a pod selects it and opens its detail; clicking the selected one again unselects it.
    private func pick(_ pod: PodSummary) {
        if selectedID == pod.id {
            selectedID = nil
        } else {
            selectedID = pod.id
            opened = pod
        }
    }

    private func row(_ pod: PodSummary) -> JSONValue { pod.queryRow(context: config.context, warnings: browse?.warnings[pod.id] ?? []) }

    @ViewBuilder private var main: some View {
        if let feature {
            content(feature)
                .environment(\.podSelectedID, selectedID)
                .sheet(item: $opened) { PodDetailSheet(pod: $0, context: config.context, feature: feature, host: host) { await feature.refresh(browsing: config.browseKey) } }
                // Each widget refreshes on its own interval; restarts when its settings change.
                .task(id: "\(config.browseKey.hashValue)|\(config.refreshInterval)") {
                    while !Task.isCancelled {
                        await feature.refresh(browsing: config.browseKey)
                        try? await Task.sleep(for: .seconds(config.refreshInterval))
                    }
                }
        } else {
            StateView(.failed(message: "The Pods feature isn't loaded."))
        }
    }

    @ViewBuilder
    private func content(_ feature: PodsFeature) -> some View {
        let browse = feature.browsing[config.browseKey]
        let pods = browse?.pods ?? []
        let visible = visiblePods
        if config.context == nil, feature.kubernetes?.isConnected != true {
            StateView(.needsConnection(names: ["Kubernetes"]), action: ("Open Settings", { host.openManager("kubernetes") }))
        } else if let error = browse?.error, browse?.lastSync == nil {
            StateView(.failed(message: error))
        } else if browse?.lastSync == nil {
            StateView(.loading("Loading pods…"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                header(feature, shown: visible.count, total: pods.count, lastSync: browse?.lastSync, error: browse?.error)
                if visible.isEmpty {
                    StateView(.empty(
                        title: pods.isEmpty ? "No pods" : config.activeFilters == ["Problems"] ? "All pods healthy" : "No pods match",
                        systemImage: "checkmark.circle", message: "Namespace \(namespaceLabel(feature))"))
                } else if layout.family == .narrow {
                    PodCounts(pods: visible, warnings: browse?.warnings ?? [:], showProblems: layout.size.height > 230) { pick($0) }
                } else if layout.family == .wide || layout.family == .large {
                    PodTable(pods: visible, warnings: browse?.warnings ?? [:], showNamespace: config.namespace == "*",
                             showNode: layout.size.width >= 820) { pick($0) }
                } else {
                    List(visible) { pod in
                        PodRow(pod: pod, subtitle: subtitle(pod), warnings: browse?.warnings[pod.id] ?? [], compact: layout.family == .narrow)
                        .contentShape(.rect)
                        .onTapGesture { pick(pod) }
                        .listRowBackground(selectedID == pod.id ? Color.accentColor.opacity(0.18) : Color.clear)
                        .contextMenu {
                            Button("Details") { opened = pod }
                            Button("Copy Name") { copy(pod.name) }
                            Button("Copy kubectl logs") { copy(PodCommands.logs(pod, context: contextName(feature))) }
                            Button("Copy kubectl exec") { copy(PodCommands.exec(pod, context: contextName(feature))) }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    /// What's shown, as set in the widget's settings: badges when there's room, one line of text when narrow.
    @ViewBuilder
    private func header(_ feature: PodsFeature, shown: Int, total: Int, lastSync: Date?, error: String?) -> some View {
        if layout.family != .narrow {
            wideHeader(feature, shown: shown, total: total, lastSync: lastSync, error: error)
        } else {
            HStack(spacing: 4) {
                Text(namespaceLabel(feature)).foregroundStyle(.tint).lineLimit(1)
                Text("· " + (shown == total ? "\(total) pods" : "\(shown)/\(total)")).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                if !config.activeFilters.isEmpty { Image(systemName: "line.3.horizontal.decrease").foregroundStyle(Tone.warning.color) }
                Spacer(minLength: 0)
                if let error { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).help(error) }
            }
            .font(.caption)
            .help([contextName(feature), namespaceLabel(feature)].compactMap { $0 }.joined(separator: " · ") + "\n" + config.activeFilters.joined(separator: " · "))
        }
    }

    private func wideHeader(_ feature: PodsFeature, shown: Int, total: Int, lastSync: Date?, error: String?) -> some View {
        HStack(spacing: 6) {
            if let context = contextName(feature) {
                Badge(context, tone: .neutral, systemImage: "server.rack").lineLimit(1).truncationMode(.middle).frame(maxWidth: 260).help("Context")
            }
            Badge(namespaceLabel(feature), tone: .info, systemImage: "square.stack.3d.up").fixedSize().help("Namespace")
            let filters = config.activeFilters
            if !filters.isEmpty {
                Badge(filters.count == 1 ? filters[0] : "\(filters.count) filters", tone: .warning, systemImage: "line.3.horizontal.decrease")
                    .help(filters.joined(separator: " · "))
            }
            Text(shown == total ? "\(total) pods" : "\(shown) of \(total)").font(.caption).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 4)
            if let error { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).help(error) }
            if let lastSync { RelativeTime(lastSync).font(.caption).foregroundStyle(.secondary).fixedSize() }
        }
    }

    private func contextName(_ feature: PodsFeature) -> String? { config.context ?? feature.cluster?.activeContext }

    private func namespaceLabel(_ feature: PodsFeature) -> String {
        switch config.namespace {
        case nil: feature.defaultNamespace(context: config.context)
        case "*": "all namespaces"
        case let name?: name
        }
    }

    private func subtitle(_ pod: PodSummary) -> String {
        [config.namespace == "*" ? pod.namespace : nil, "\(pod.ready)/\(pod.total) ready", PodSummary.age(since: pod.created), pod.node]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One pod: the name on one line (cut in the middle, where hashes are), details below, and the
/// status as a badge; narrow widgets fold the status into the details line.
private struct PodRow: View {
    let pod: PodSummary
    let subtitle: String
    let warnings: [String]
    let compact: Bool

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(pod.tone, help: pod.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(pod.name).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(compact ? [pod.status, pod.restarts > 0 ? "↻\(pod.restarts)" : nil, warnings.first].compactMap { $0 }.joined(separator: " · ") : subtitle)
                    .font(.caption).foregroundStyle(compact && pod.tone != .success ? pod.tone.color : .secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            .help(pod.name + "\n" + subtitle)
            if !compact {
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
        }
        .padding(.vertical, 2)
    }
}

/// Narrow widgets: how many pods are running, failing, starting and done, and (when there's
/// height) the pods with problems.
private struct PodCounts: View {
    let pods: [PodSummary]
    let warnings: [String: [String]]
    let showProblems: Bool
    let open: (PodSummary) -> Void

    var body: some View {
        let failing = pods.filter { $0.tone == .danger }
        let starting = pods.filter { $0.tone == .warning }
        let running = pods.filter { $0.tone == .success }
        let done = pods.filter { $0.phase == "Succeeded" }
        VStack(alignment: .leading, spacing: 10) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    count(running.count, "running", .success)
                    count(failing.count, "failing", .danger)
                }
                GridRow {
                    count(starting.count, "not ready", .warning)
                    count(done.count, "completed", .neutral)
                }
            }
            let restarts = pods.reduce(0) { $0 + $1.restarts }
            if restarts > 0 {
                Label("\(restarts) restarts", systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.secondary)
            }
            if showProblems, !(failing + starting).isEmpty {
                List(failing + starting) { pod in
                    HStack(spacing: 6) {
                        StatusDot(pod.tone, help: pod.status)
                        Text(pod.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 2)
                        Text(warnings[pod.id]?.first ?? pod.status).font(.caption2).foregroundStyle(pod.tone.color).lineLimit(1)
                    }
                    .contentShape(.rect)
                    .onTapGesture { open(pod) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private func count(_ value: Int, _ label: String, _ tone: Tone) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.title2.bold()).monospacedDigit().foregroundStyle(value > 0 && tone != .neutral ? tone.color : .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
    }
}

/// Wide widgets: kubectl get pods as a table. The header and the rows share one set of
/// column widths and margins. Click a row for the pod's details.
private struct PodTable: View {
    let pods: [PodSummary]
    let warnings: [String: [String]]
    let showNamespace: Bool
    let showNode: Bool
    let open: (PodSummary) -> Void
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
                            .onTapGesture { open(pod) }
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
            if showNamespace { namespace.lineLimit(1).truncationMode(.tail).frame(width: 130, alignment: .leading) }
            ready.frame(width: 44, alignment: .leading)
            status.lineLimit(1).frame(width: 136, alignment: .leading)
            restarts.frame(width: 56, alignment: .trailing)
            age.frame(width: 40, alignment: .trailing)
            if showNode { node.lineLimit(1).truncationMode(.middle).frame(minWidth: 100, maxWidth: 240, alignment: .leading) }
        }
        .padding(.horizontal, 8)
    }
}

extension EnvironmentValues {
    /// The pod picked in the widget, drawn as selected.
    @Entry var podSelectedID: String? = nil
}
