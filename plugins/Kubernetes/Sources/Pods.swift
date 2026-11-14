import DashKit
import DashKitUI
import Foundation

/// One pod, as `kubectl get pods` shows it.
struct PodSummary: Equatable, Sendable, Identifiable {
    var namespace: String
    var name: String
    /// status.phase: Pending, Running, Succeeded, Failed, Unknown.
    var phase: String
    /// kubectl's STATUS column: the phase, or a container's waiting/terminated reason
    /// (CrashLoopBackOff, ImagePullBackOff, OOMKilled…), or Terminating.
    var status: String
    var ready: Int
    var total: Int
    var restarts: Int
    var node: String?

    var id: String { "\(namespace)/\(name)" }
    var isCrashLooping: Bool { status == "CrashLoopBackOff" }

    init(namespace: String, name: String, phase: String, status: String? = nil, ready: Int = 0, total: Int = 0, restarts: Int = 0, node: String? = nil) {
        self.namespace = namespace
        self.name = name
        self.phase = phase
        self.status = status ?? phase
        self.ready = ready
        self.total = total
        self.restarts = restarts
        self.node = node
    }

    init?(_ pod: JSONValue) {
        guard let name = pod["metadata"]?["name"]?.string else { return nil }
        self.name = name
        namespace = pod["metadata"]?["namespace"]?.string ?? ""
        let status = pod["status"]
        phase = status?["phase"]?.string ?? "Unknown"
        node = pod["spec"]?["nodeName"]?.string
        let containers = status?["containerStatuses"]?.array ?? []
        total = max(containers.count, pod["spec"]?["containers"]?.array?.count ?? 0)
        ready = containers.filter { $0["ready"]?.bool == true }.count
        restarts = containers.compactMap { $0["restartCount"]?.int }.reduce(0, +)

        var reason = status?["reason"]?.string ?? phase
        // Init containers that haven't finished explain a Pending pod.
        let initContainers = status?["initContainerStatuses"]?.array ?? []
        var initializing = false
        for (index, container) in initContainers.enumerated() {
            if let terminated = container["state"]?["terminated"], terminated["exitCode"]?.int == 0 { continue }
            if let waiting = container["state"]?["waiting"]?["reason"]?.string, waiting != "PodInitializing" {
                reason = "Init:\(waiting)"
            } else if let terminated = container["state"]?["terminated"] {
                reason = "Init:" + (terminated["reason"]?.string ?? "ExitCode:\(terminated["exitCode"]?.int ?? 0)")
            } else {
                reason = "Init:\(index)/\(initContainers.count)"
            }
            initializing = true
            break
        }
        if !initializing {
            for container in containers.reversed() {
                if let waiting = container["state"]?["waiting"]?["reason"]?.string, !waiting.isEmpty {
                    reason = waiting
                } else if let terminated = container["state"]?["terminated"] {
                    reason = terminated["reason"]?.string ?? "ExitCode:\(terminated["exitCode"]?.int ?? 0)"
                }
            }
        }
        if pod["metadata"]?["deletionTimestamp"]?.string != nil { reason = "Terminating" }
        self.status = reason
    }

    /// Tone for badges and dots.
    var tone: Tone {
        if isCrashLooping || status.hasSuffix("BackOff") || status.hasPrefix("Err") || status == "OOMKilled" || phase == "Failed" { return .danger }
        if status == "Terminating" || phase == "Pending" || status.hasPrefix("Init:") || phase == "Unknown" { return .warning }
        if phase == "Succeeded" || status == "Completed" { return .neutral }
        if phase == "Running" { return ready == total ? .success : .warning }
        return .neutral
    }

    var json: JSONValue {
        [
            "namespace": .string(namespace), "name": .string(name), "phase": .string(phase), "status": .string(status),
            "ready": .string("\(ready)/\(total)"), "restarts": .number(Double(restarts)), "node": node.map(JSONValue.string) ?? .null,
        ]
    }

    /// Pods of a PodList, sorted by namespace then name.
    static func list(_ podList: JSONValue) -> [PodSummary] {
        (podList["items"]?.array ?? []).compactMap(PodSummary.init).sorted { ($0.namespace, $0.name) < ($1.namespace, $1.name) }
    }

    /// REST path listing pods: one namespace, or every namespace for nil/"" /"*"/"all".
    static func path(namespace: String?, labelSelector: String? = nil, fieldSelector: String? = nil, limit: Int? = nil) -> String {
        let all = namespace.map { $0.isEmpty || $0 == "*" || $0 == "all" } ?? true
        var components = URLComponents()
        components.path = all ? "/api/v1/pods" : "/api/v1/namespaces/\(namespace!)/pods"
        var query: [URLQueryItem] = []
        if let labelSelector, !labelSelector.isEmpty { query.append(URLQueryItem(name: "labelSelector", value: labelSelector)) }
        if let fieldSelector, !fieldSelector.isEmpty { query.append(URLQueryItem(name: "fieldSelector", value: fieldSelector)) }
        if let limit { query.append(URLQueryItem(name: "limit", value: String(limit))) }
        if !query.isEmpty { components.queryItems = query }
        // URLComponents leaves "=" and "," alone in queries; "+" must be escaped for selectors like "a in (x)".
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.string ?? components.path
    }
}
