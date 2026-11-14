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
        version: "1.1.0", author: .dash, summary: "Pods in your Kubernetes namespace, with crash-loop alerts.",
        category: .cloud, tags: ["kubernetes", "pods"], minimumDashKit: "1.3.0")

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
    struct Config: Codable, Equatable, Sendable {
        /// Hide pods that are running and ready, or completed.
        var problemsOnly: Bool
    }

    static let kind = "kubernetes.pods"
    static let displayName = "Pods"
    static let summary = "Pods in the configured Kubernetes namespace with their status and restarts, refreshed every 30 seconds."
    static let systemImage = "cube.box"
    static let defaultSize = WidgetSize.medium
    static let defaultConfig = Config(problemsOnly: false)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["problemsOnly": ["type": "boolean", "description": "Only show pods that aren't healthy."]],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        PodsWidgetView(feature: context.host.ext(PodsFeature.self), host: context.host, problemsOnly: config.wrappedValue.problemsOnly)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Only pods with problems", isOn: config.problemsOnly)
    }

    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)

    /// Sample pods for the widget gallery (never the cluster).
    static func preview(config: Config) -> some View {
        let samples: [(String, String, Tone, String, Int)] = [
            ("api-7d9f8c6b5-x2lqp", "2/2 ready · gke-pool-a-1", .success, "Running", 0),
            ("api-7d9f8c6b5-k9wzt", "2/2 ready · gke-pool-a-2", .success, "Running", 0),
            ("worker-5c4b7d8f9-mn3vr", "0/1 ready · gke-pool-b-1", .danger, "CrashLoopBackOff", 7),
            ("migrate-28431-q8s7d", "0/1 ready · gke-pool-a-1", .neutral, "Completed", 0),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Badge("default", tone: .info, systemImage: "square.stack.3d.up")
                Text("4 pods").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(samples, id: \.0) { name, subtitle, tone, status, restarts in
                ItemRow(name, subtitle: subtitle, monospacedTitle: true, leading: { StatusDot(tone) }, trailing: {
                    HStack(spacing: 4) {
                        if restarts > 0 { Badge("\(restarts) restarts", tone: .danger, systemImage: "arrow.clockwise") }
                        Badge(status, tone: tone)
                    }
                })
            }
        }
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        context.host.ext(PodsFeature.self)?.snapshot ?? .null
    }
}

private struct PodsWidgetView: View {
    let feature: PodsFeature?
    let host: any ExtensionContext
    let problemsOnly: Bool

    var body: some View {
        if let feature {
            content(feature)
        } else {
            StateView(.failed(message: "The Pods feature isn't loaded."))
        }
    }

    @ViewBuilder
    private func content(_ feature: PodsFeature) -> some View {
        let visible = feature.pods.filter { !problemsOnly || ![.success, .neutral].contains($0.tone) }
        if feature.kubernetes?.isConnected != true {
            StateView(.needsConnection(names: ["Kubernetes"]), action: ("Open Settings", { host.openManager("kubernetes") }))
        } else if let error = feature.lastError, feature.lastSync == nil {
            StateView(.failed(message: error), action: ("Retry", { Task { await feature.refresh() } }))
        } else if feature.lastSync == nil {
            StateView(.loading("Loading pods…"))
                .task { await feature.refresh() }
        } else if visible.isEmpty {
            StateView(.empty(
                title: problemsOnly && !feature.pods.isEmpty ? "All pods healthy" : "No pods",
                systemImage: "checkmark.circle", message: "Namespace \(feature.namespace ?? "default")"))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Badge(feature.namespace ?? "default", tone: .info, systemImage: "square.stack.3d.up")
                    Text("\(visible.count) pods").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let error = feature.lastError {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).help(error)
                    }
                    if let lastSync = feature.lastSync { RelativeTime(lastSync).font(.caption).foregroundStyle(.secondary) }
                }
                List(visible) { pod in
                    ItemRow(pod.name, subtitle: subtitle(pod), monospacedTitle: true, leading: {
                        StatusDot(pod.tone, help: pod.status)
                    }, trailing: {
                        HStack(spacing: 4) {
                            if pod.restarts > 0 { Badge("\(pod.restarts) restarts", tone: pod.isCrashLooping ? .danger : .warning, systemImage: "arrow.clockwise") }
                            Badge(pod.status, tone: pod.tone)
                        }
                    })
                }
                .listStyle(.plain)
            }
        }
    }

    private func subtitle(_ pod: PodSummary) -> String {
        ["\(pod.ready)/\(pod.total) ready", pod.node].compactMap { $0 }.joined(separator: " · ")
    }
}
