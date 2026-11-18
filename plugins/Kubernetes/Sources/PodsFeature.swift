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
        version: "1.12.0", author: .dash, summary: "Browse pods like k9s: context, namespace, filters, and a detail view with logs, events and YAML.",
        category: .cloud, tags: ["kubernetes", "pods"], minimumDashKit: "2.4.0")

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
