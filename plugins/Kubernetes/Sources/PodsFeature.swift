import AppKit
import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Layer 2 on Kubernetes: pods of the configured namespace, refreshed every 30 seconds,
/// with an activity event when a pod starts crash-looping.
@MainActor
@Observable
final class PodsFeature: DashExtension {
    let id = "kubernetes-pods"
    let name = "Pods"
    let systemImage = "cube.box"
    let requires = ["kubernetes"]
    let metadata = ExtensionMetadata(
        version: "1.3.0", author: .dash, summary: "Browse pods like k9s: context, namespace, filters, and a detail view with logs, events and YAML.",
        category: .cloud, tags: ["kubernetes", "pods"], minimumDashKit: "1.4.0")

    static let refreshInterval: Duration = .seconds(30)

    private(set) var pods: [PodSummary] = []
    private(set) var namespace: String?
    private(set) var context: String?
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isRefreshing = false

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var poller: Task<Void, Never>?
    /// Pods last seen in CrashLoopBackOff, so each episode is reported once.
    @ObservationIgnored private var crashLooping: Set<String> = []

    var widgets: [WidgetType] { [WidgetType(PodsWidget.self)] }

    var kubernetes: (any Integration)? { host?.integration("kubernetes") }
    var cluster: KubernetesIntegration? { kubernetes as? KubernetesIntegration }

    /// What a widget lists: a context (nil is the active one), a namespace ("" is the context's own,
    /// "*" every namespace), a server-side label selector, and whether to fetch events too.
    struct BrowseKey: Hashable, Sendable {
        var context: String?
        var namespace: String
        var labelSelector: String?
        var events: Bool
    }

    struct Browse: Equatable {
        var pods: [PodSummary] = []
        /// Recent Warning event reasons per pod id ("namespace/name"), when the widget asked for events.
        var warnings: [String: [String]] = [:]
        var lastSync: Date?
        var error: String?
    }

    private(set) var browsing: [BrowseKey: Browse] = [:]
    /// Each context's namespaces, for the widget settings ("" is the active context).
    private(set) var namespaces: [String: [String]] = [:]

    /// The namespace a context uses when a widget doesn't pick one.
    func defaultNamespace(context: String?) -> String {
        guard let cluster else { return "default" }
        guard let context, !context.isEmpty, context != cluster.activeContext else { return cluster.namespace }
        return (try? cluster.config?.resolve(context))?.namespace ?? "default"
    }

    /// Fetches what a widget shows. Each widget calls this on its own refresh interval.
    func refresh(browsing key: BrowseKey) async {
        guard let cluster, let connection = cluster.connection(context: key.context) else {
            browsing[key, default: Browse()].error = "Can't connect to context \(key.context ?? cluster?.activeContext ?? "in use")."
            return
        }
        let namespace = key.namespace.isEmpty ? defaultNamespace(context: key.context) : key.namespace
        do {
            let list = try await connection.get(PodSummary.path(namespace: namespace, labelSelector: key.labelSelector), service: "Kubernetes")
            var warnings: [String: [String]] = [:]
            if key.events {
                let path = namespace == "*" ? "/api/v1/events" : "/api/v1/namespaces/\(namespace)/events"
                let selector = "type=Warning,involvedObject.kind=Pod".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
                if let events = try? await connection.get("\(path)?fieldSelector=\(selector)", service: "Kubernetes") {
                    warnings = PodSummary.warnings(events)
                }
            }
            browsing[key] = Browse(pods: PodSummary.list(list), warnings: warnings, lastSync: .now)
        } catch {
            browsing[key, default: Browse()].error = error.localizedDescription
        }
    }

    func loadNamespaces(context: String?) async {
        guard let connection = cluster?.connection(context: context),
              let list = try? await connection.get("/api/v1/namespaces", service: "Kubernetes") else { return }
        namespaces[context ?? ""] = (list["items"]?.array ?? []).compactMap { $0["metadata"]?["name"]?.string }.sorted()
    }

    func start(host: any ExtensionContext) {
        self.host = host
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
    }

    var isRunning: Bool { poller != nil }

    func refresh() async {
        guard !isRefreshing, let kubernetes, kubernetes.isConnected, let connection = kubernetes.connection else { return }
        let namespace = kubernetes.exports["namespace"]?.string ?? "default"
        let context = kubernetes.exports["currentContext"]?.string
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let list = try await connection.get(PodSummary.path(namespace: namespace), service: "Kubernetes")
            apply(PodSummary.list(list), namespace: namespace, context: context)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stores a fresh list and reports pods that entered CrashLoopBackOff since the last one.
    func apply(_ list: [PodSummary], namespace: String, context: String?) {
        if namespace != self.namespace || context != self.context { crashLooping = [] }
        for pod in list where pod.isCrashLooping && !crashLooping.contains(pod.id) {
            host?.emit(
                "pod.crashloop", from: self, title: "Pod \(pod.name) is in CrashLoopBackOff",
                detail: "\(pod.namespace) on \(context ?? "the current context") · \(pod.restarts) restarts", importance: .notable)
        }
        crashLooping = Set(list.filter(\.isCrashLooping).map(\.id))
        pods = list
        self.namespace = namespace
        self.context = context
        lastSync = .now
        lastError = nil
    }

    var snapshot: JSONValue {
        [
            "context": context.map(JSONValue.string) ?? .null, "namespace": namespace.map(JSONValue.string) ?? .null,
            "lastSync": lastSync.map { .string($0.formatted(.iso8601)) } ?? .null, "error": lastError.map(JSONValue.string) ?? .null,
            "pods": .array(pods.map(\.json)),
        ]
    }
}

// MARK: - Widget

struct PodsWidget: DashboardWidget {
    /// Everything here is chosen in the widget's settings; the widget itself only shows it.
    struct Config: Codable, Equatable, Sendable {
        /// Hide pods that are running and ready, or completed. (Older widgets; `filter` replaces it.)
        var problemsOnly: Bool
        /// Kubeconfig context; nil follows the one the Kubernetes integration uses.
        var context: String?
        /// Namespace; nil uses the context's own, "*" is every namespace.
        var namespace: String?
        var filter: String?
        var sort: String?
        var search: String?
        /// Server-side label selector, e.g. "app=web,tier!=cache".
        var labelSelector: String?
        var node: String?
        var controller: String?
        var minRestarts: Int?
        /// Only pods younger than this many seconds.
        var maxAge: Int?
        /// "any" or a Warning reason; nil doesn't fetch events.
        var event: String?
        /// Seconds between refreshes (default 30).
        var refresh: Int?

        var statusFilter: PodSummary.Filter { filter.flatMap(PodSummary.Filter.init) ?? (problemsOnly ? .problems : .all) }
        var podSort: PodSummary.Sort { sort.flatMap(PodSummary.Sort.init) ?? .name }
        var refreshInterval: Int { max(5, refresh ?? 30) }

        var browseKey: PodsFeature.BrowseKey {
            PodsFeature.BrowseKey(context: context, namespace: namespace ?? "", labelSelector: labelSelector?.nilIfBlank, events: event != nil)
        }

        var query: PodQuery {
            PodQuery(status: statusFilter, search: search ?? "", node: node?.nilIfBlank, controller: controller, minRestarts: minRestarts,
                     maxAge: maxAge.map(TimeInterval.init), event: event)
        }

        /// Short labels for the filters in use, shown on the widget.
        var activeFilters: [String] {
            var labels: [String] = []
            if statusFilter != .all { labels.append(statusFilter.title) }
            if let event { labels.append(event == "any" ? "Warnings" : event) }
            if let labelSelector = labelSelector?.nilIfBlank { labels.append(labelSelector) }
            if let node = node?.nilIfBlank { labels.append("node \(node)") }
            if let controller { labels.append(controller == "none" ? "No controller" : controller) }
            if let minRestarts { labels.append("≥\(minRestarts) restarts") }
            if let maxAge { labels.append("< \(PodSummary.age(since: Date(timeIntervalSinceNow: -TimeInterval(maxAge))))") }
            if let search = search?.nilIfBlank { labels.append("“\(search)”") }
            return labels
        }
    }

    static let kind = "kubernetes.pods"
    static let displayName = "Pods"
    static let summary = "Browse pods like k9s. In the widget's settings: context, namespace, status, warning events, labels, node, controller, restarts, age, search, sort and refresh rate. Click a pod for its containers, events, logs and YAML."
    static let systemImage = "cube.box"
    static let defaultSize = WidgetSize.medium
    static let defaultConfig = Config(problemsOnly: false)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "problemsOnly": ["type": "boolean", "description": "Only show pods that aren't healthy."],
            "context": ["type": "string", "description": "Kubeconfig context; omit for the one the Kubernetes integration uses."],
            "namespace": ["type": "string", "description": "Namespace to show; omit for the context's own, \"*\" for all."],
            "filter": ["type": "string", "enum": ["all", "problems", "running", "pending", "failed", "completed"]],
            "sort": ["type": "string", "enum": ["name", "status", "restarts", "age"]],
            "search": ["type": "string", "description": "Words match name, node, status, IP or owner; key=value matches a label; !word excludes."],
            "labelSelector": ["type": "string", "description": "Kubernetes label selector, e.g. app=web,tier!=cache."],
            "node": ["type": "string", "description": "Part of the node name."],
            "controller": ["type": "string", "enum": .array(PodQuery.controllers.map { .string($0) })],
            "minRestarts": ["type": "integer", "description": "Only pods restarted at least this often."],
            "maxAge": ["type": "integer", "description": "Only pods younger than this many seconds."],
            "event": ["type": "string", "description": "Only pods with a recent Warning event: \"any\" or a reason (BackOff, Unhealthy, FailedScheduling…)."],
            "refresh": ["type": "integer", "description": "Seconds between refreshes (default 30)."],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        PodsWidgetView(feature: context.host.ext(PodsFeature.self), host: context.host, config: config.wrappedValue)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        PodsWidgetSettings(feature: context.host.ext(PodsFeature.self), config: config)
    }

    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)

    /// Sample pods for the widget gallery (never the cluster).
    static func preview(config: Config) -> some View {
        let samples: [(String, String, Tone, String, Int)] = [
            ("api-7d9f8c6b5-x2lqp", "2/2 ready · 3d · gke-pool-a-1", .success, "Running", 0),
            ("api-7d9f8c6b5-k9wzt", "2/2 ready · 3d · gke-pool-a-2", .success, "Running", 0),
            ("worker-5c4b7d8f9-mn3vr", "0/1 ready · 12m · gke-pool-b-1", .danger, "CrashLoopBackOff", 7),
            ("migrate-28431-q8s7d", "0/1 ready · 2h · gke-pool-a-1", .neutral, "Completed", 0),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Badge("gke-prod", tone: .neutral, systemImage: "server.rack")
                Badge("default", tone: .info, systemImage: "square.stack.3d.up")
                Text("4 pods").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(samples, id: \.0) { name, subtitle, tone, status, restarts in
                ItemRow(name, subtitle: subtitle, monospacedTitle: true, leading: { StatusDot(tone) }, trailing: {
                    HStack(spacing: 4) {
                        if restarts > 0 { Badge("\(restarts)", tone: .danger, systemImage: "arrow.clockwise") }
                        Badge(status, tone: tone)
                    }
                })
            }
        }
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let feature = context.host.ext(PodsFeature.self) else { return .null }
        let browse = feature.browsing[config.browseKey]
        let pods = (browse?.pods ?? []).filter { config.query.matches($0, warnings: browse?.warnings[$0.id] ?? []) }
        return ["context": config.context.map(JSONValue.string) ?? feature.snapshot["context"] ?? .null,
                "namespace": .string(config.namespace ?? feature.defaultNamespace(context: config.context)),
                "filters": .array(config.activeFilters.map { .string($0) }),
                "lastSync": browse?.lastSync.map { .string($0.formatted(.iso8601)) } ?? .null,
                "error": browse?.error.map(JSONValue.string) ?? .null,
                "pods": .array(pods.map { pod in
                    var json = pod.json
                    if let warnings = browse?.warnings[pod.id], case .object(var fields) = json {
                        fields["warnings"] = .array(warnings.map { .string($0) })
                        json = .object(fields)
                    }
                    return json
                })]
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The widget's settings: what it shows and how often it refreshes.
private struct PodsWidgetSettings: View {
    let feature: PodsFeature?
    @Binding var config: PodsWidget.Config

    var body: some View {
        let contexts = feature?.cluster?.contextNames ?? []
        let namespaces = feature?.namespaces[config.context ?? ""] ?? []
        Section("Source") {
            Picker("Context", selection: $config.context) {
                Text("Same as Kubernetes settings (\(feature?.cluster?.activeContext ?? "none"))").tag(String?.none)
                ForEach(contexts, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Namespace", selection: $config.namespace) {
                Text("Context's own (\(feature?.defaultNamespace(context: config.context) ?? "default"))").tag(String?.none)
                Text("All namespaces").tag(String?.some("*"))
                ForEach(namespaces, id: \.self) { Text($0).tag(String?.some($0)) }
                if let current = config.namespace, current != "*", !namespaces.contains(current) { Text(current).tag(String?.some(current)) }
            }
            .task(id: config.context) { await feature?.loadNamespaces(context: config.context) }
            TextField("Label selector", text: text(\.labelSelector), prompt: Text("app=web,tier!=cache"))
            Picker("Refresh", selection: Binding(get: { config.refreshInterval }, set: { config.refresh = $0 })) {
                ForEach([10, 30, 60, 120, 300, 900], id: \.self) { seconds in
                    Text(seconds < 60 ? "Every \(seconds) seconds" : "Every \(seconds / 60) minute\(seconds == 60 ? "" : "s")").tag(seconds)
                }
            }
        }
        Section("Filters") {
            Picker("Status", selection: Binding(get: { config.statusFilter }, set: {
                config.filter = $0.rawValue
                config.problemsOnly = $0 == .problems
            })) {
                ForEach(PodSummary.Filter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Events", selection: $config.event) {
                Text("Any").tag(String?.none)
                Text("Has warning events").tag(String?.some("any"))
                Divider()
                ForEach(PodQuery.eventReasons, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .help("Warning events from the last hour")
            Picker("Controller", selection: $config.controller) {
                Text("Any").tag(String?.none)
                ForEach(PodQuery.controllers, id: \.self) { Text($0 == "none" ? "None (bare pods)" : $0).tag(String?.some($0)) }
            }
            Picker("Restarts", selection: $config.minRestarts) {
                Text("Any").tag(Int?.none)
                ForEach([1, 3, 5, 10], id: \.self) { Text("At least \($0)").tag(Int?.some($0)) }
            }
            Picker("Age", selection: $config.maxAge) {
                Text("Any").tag(Int?.none)
                ForEach([600, 3600, 6 * 3600, 86400, 7 * 86400], id: \.self) { seconds in
                    Text("Younger than \(PodSummary.age(since: Date(timeIntervalSinceNow: -TimeInterval(seconds))))").tag(Int?.some(seconds))
                }
            }
            TextField("Node", text: text(\.node), prompt: Text("part of the node name"))
            TextField("Search", text: text(\.search), prompt: Text("name, IP, app=web, !Running"))
            Picker("Sort by", selection: Binding(get: { config.podSort }, set: { config.sort = $0.rawValue })) {
                ForEach(PodSummary.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private func text(_ path: WritableKeyPath<PodsWidget.Config, String?>) -> Binding<String> {
        Binding(get: { config[keyPath: path] ?? "" }, set: { config[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
}

private struct PodsWidgetView: View {
    let feature: PodsFeature?
    let host: any ExtensionContext
    let config: PodsWidget.Config
    @State private var selected: PodSummary?
    /// The widget's size family, from the dashboard: each gets its own layout.
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        if let feature {
            content(feature)
                .sheet(item: $selected) { PodDetailSheet(pod: $0, context: config.context, feature: feature, host: host) { await feature.refresh(browsing: config.browseKey) } }
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
        let query = config.query
        let visible = PodSummary.sorted(pods.filter { query.matches($0, warnings: browse?.warnings[$0.id] ?? []) }, by: config.podSort)
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
                    PodCounts(pods: visible, warnings: browse?.warnings ?? [:], showProblems: layout.size.height > 230) { selected = $0 }
                } else if layout.family == .wide || layout.family == .large {
                    PodTable(pods: visible, warnings: browse?.warnings ?? [:], showNamespace: config.namespace == "*",
                             showNode: layout.size.width >= 820) { selected = $0 }
                } else {
                    List(visible) { pod in
                        PodRow(pod: pod, subtitle: subtitle(pod), warnings: browse?.warnings[pod.id] ?? [], compact: layout.family == .narrow)
                        .contentShape(.rect)
                        .onTapGesture { selected = pod }
                        .contextMenu {
                            Button("Details") { selected = pod }
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

    var body: some View {
        VStack(spacing: 0) {
            columns(dot: AnyView(Color.clear), name: Text("Name"), namespace: Text("Namespace"), ready: Text("Ready"),
                    status: AnyView(Text("Status")), restarts: Text("Restarts"), age: Text("Age"), node: Text("Node"))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.vertical, 5)
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
                            .background(hovered == pod.id ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
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
            name.lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
            if showNamespace { namespace.lineLimit(1).truncationMode(.tail).frame(width: 130, alignment: .leading) }
            ready.frame(width: 44, alignment: .leading)
            status.lineLimit(1).frame(width: 150, alignment: .leading)
            restarts.frame(width: 60, alignment: .trailing)
            age.frame(width: 40, alignment: .trailing)
            if showNode { node.lineLimit(1).truncationMode(.middle).frame(width: 220, alignment: .leading) }
        }
        .padding(.horizontal, 8)
    }
}
