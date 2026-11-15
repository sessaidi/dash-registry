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
        version: "1.5.0", author: .dash, summary: "Browse pods like k9s: context, namespace, filters, and a detail view with logs, events and YAML.",
        category: .cloud, tags: ["kubernetes", "pods"], minimumDashKit: "1.5.0")

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

    static let actions = PodsWidgetActions.actions
    static let queryFields = PodSummary.queryFields

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        PodsWidgetView(feature: context.host.ext(PodsFeature.self), host: context.host, config: config,
                       query: context.query(fields: PodSummary.queryFields), queryText: context.queryText)
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
        return ["explanation": """
                    Pods of one namespace (or all, "*") of a kubeconfig context, after the widget's filters. status is what \
                    kubectl shows (Running, Pending, CrashLoopBackOff, ImagePullBackOff, Completed…); ready is ready/total \
                    containers; restarts count container restarts (many restarts or CrashLoopBackOff means the container keeps \
                    crashing); warnings are recent Warning event reasons (BackOff, Unhealthy, FailedScheduling…). A healthy \
                    pod is Running with all containers ready; Completed pods (jobs) finished successfully.
                    """,
                "context": config.context.map(JSONValue.string) ?? feature.snapshot["context"] ?? .null,
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
/// What Dashii can do with a Pods widget, kept apart from the view so it can be tested.
enum PodsWidgetActions {
    static let actions = [
        WidgetAction(name: "filter", description: "Search the pods: words match name, node, status, IP or owner; key=value matches a label; !word excludes. Empty clears it.",
                     properties: ["text": JSONSchema.string("Search text.")], required: ["text"]),
        WidgetAction(name: "set_status", description: "Show pods by status.",
                     properties: ["status": JSONSchema.string("all, problems, running, pending, failed or completed.", enum: ["all", "problems", "running", "pending", "failed", "completed"])], required: ["status"]),
        WidgetAction(name: "show_problems_only", description: "Only pods that aren't healthy (on), or every pod (off).",
                     properties: ["on": JSONSchema.boolean("true for problems only.")], required: ["on"]),
        WidgetAction(name: "set_namespace", description: "Show another namespace: a name, \"*\" for every namespace, or \"\" for the context's own.",
                     properties: ["namespace": JSONSchema.string("Namespace.")], required: ["namespace"]),
        WidgetAction(name: "set_context", description: "Show another kubeconfig context; \"\" follows the one the Kubernetes integration uses.",
                     properties: ["context": JSONSchema.string("Context name.")], required: ["context"]),
        WidgetAction(name: "select_pod", description: "Open a pod's detail (containers, events, logs, YAML) by name or a unique part of it.",
                     properties: ["name": JSONSchema.string("Pod name.")], required: ["name"]),
        WidgetAction(name: "clear_filters", description: "Remove the search and status filters."),
    ]

    struct Outcome {
        var reply: JSONValue
        var select: PodSummary?
    }

    static func perform(_ name: String, _ input: JSONValue, config: inout PodsWidget.Config, pods: [PodSummary]) throws -> Outcome {
        switch name {
        case "filter":
            let text = input["text"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            config.search = text.isEmpty ? nil : text
            return Outcome(reply: ["search": text.isEmpty ? .null : .string(text)])
        case "set_status":
            guard let raw = input["status"]?.string, let status = PodSummary.Filter(rawValue: raw) else {
                throw ToolError("Status is one of all, problems, running, pending, failed, completed.")
            }
            config.filter = status.rawValue
            config.problemsOnly = status == .problems
            return Outcome(reply: ["status": .string(status.rawValue)])
        case "show_problems_only":
            let on = input["on"]?.bool ?? true
            config.filter = on ? PodSummary.Filter.problems.rawValue : PodSummary.Filter.all.rawValue
            config.problemsOnly = on
            return Outcome(reply: ["problems_only": .bool(on)])
        case "set_namespace":
            let namespace = input["namespace"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            config.namespace = namespace.isEmpty ? nil : namespace
            return Outcome(reply: ["namespace": namespace.isEmpty ? "context's own" : .string(namespace)])
        case "set_context":
            let context = input["context"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
            config.context = context.isEmpty ? nil : context
            config.namespace = nil
            return Outcome(reply: ["context": context.isEmpty ? "integration's" : .string(context)])
        case "select_pod":
            let wanted = input["name"]?.string?.lowercased() ?? ""
            let matches = pods.filter { $0.name.lowercased().contains(wanted) }
            guard !wanted.isEmpty, let pod = pods.first(where: { $0.name.lowercased() == wanted }) ?? (matches.count == 1 ? matches[0] : nil) else {
                throw ToolError(matches.count > 1 ? "Several pods match “\(wanted)”: \(matches.prefix(8).map(\.name).joined(separator: ", "))."
                                                  : "No pod matching “\(wanted)” is shown.")
            }
            return Outcome(reply: ["opened": .string(pod.id)], select: pod)
        case "clear_filters":
            config.search = nil
            config.filter = nil
            config.problemsOnly = false
            return Outcome(reply: "cleared")
        default:
            throw ToolError("Unknown action \(name).")
        }
    }

    static func state(config: PodsWidget.Config, pods: [PodSummary], total: Int, namespace: String, selected: PodSummary?) -> JSONValue {
        [
            "context": config.context.map(JSONValue.string) ?? "integration's",
            "namespace": .string(namespace),
            "status": .string(config.statusFilter.rawValue),
            "search": config.search.map(JSONValue.string) ?? .null,
            "filters": .array(config.activeFilters.map { .string($0) }),
            "shown": .number(Double(pods.count)), "total": .number(Double(total)),
            "counts": [
                "running": .number(Double(pods.filter { $0.tone == .success }.count)),
                "failing": .number(Double(pods.filter { $0.tone == .danger }.count)),
                "not_ready": .number(Double(pods.filter { $0.tone == .warning }.count)),
                "completed": .number(Double(pods.filter { $0.phase == "Succeeded" }.count)),
                "restarts": .number(Double(pods.reduce(0) { $0 + $1.restarts })),
            ],
            "open_pod": selected.map { .string($0.id) } ?? .null,
        ]
    }
}

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
    @Binding var config: PodsWidget.Config
    /// The widget's DashQL query (its query bar), applied after the settings' filters.
    let query: WidgetQuery?
    let queryText: String
    @State private var selected: PodSummary?
    @State private var queryIDs: [String]?
    /// The widget's size family, from the dashboard: each gets its own layout.
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        main
            .handlesWidgetActions { name, input in
                let result = try PodsWidgetActions.perform(name, input, config: &config, pods: visiblePods)
                if let pod = result.select { selected = pod }
                return result.reply
            }
            .reportsWidgetState(PodsWidgetActions.state(config: config, pods: visiblePods, total: browse?.pods.count ?? 0,
                                                        namespace: feature.map(namespaceLabel) ?? "", selected: selected))
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

    private func row(_ pod: PodSummary) -> JSONValue { pod.queryRow(context: config.context, warnings: browse?.warnings[pod.id] ?? []) }

    @ViewBuilder private var main: some View {
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
