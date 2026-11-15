import DashKit
import DashKitUI
import Foundation
import SwiftUI

/// Pods: browse pods like k9s, with a detail sheet per pod.
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
        PodsWidgetView(feature: context.host.ext(PodsFeature.self), host: context.host, settings: config,
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
