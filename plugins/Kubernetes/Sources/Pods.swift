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
    var created: Date?
    var podIP: String?
    var labels: [String: String] = [:]
    /// The controller that owns the pod ("ReplicaSet/api-7d9f8c6b5"), if any.
    var owner: String?
    var containers: [String] = []

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
        created = pod["metadata"]?["creationTimestamp"]?.string.flatMap { try? Date($0, strategy: .iso8601) }
        podIP = status?["podIP"]?.string
        labels = (pod["metadata"]?["labels"]?.object ?? [:]).compactMapValues(\.string)
        owner = pod["metadata"]?["ownerReferences"]?.array?.first.map { "\($0["kind"]?.string ?? "?")/\($0["name"]?.string ?? "?")" }
        containers = (pod["spec"]?["containers"]?.array ?? []).compactMap { $0["name"]?.string }
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

    /// kubectl's AGE column: 45s, 12m, 5h, 3d.
    static func age(since date: Date?, now: Date = .now) -> String {
        guard let date else { return "?" }
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<120: return "\(seconds)s"
        case ..<7200: return "\(seconds / 60)m"
        case ..<172_800: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }

    /// k9s-style filter: words must all match the name, node, status, IP or owner;
    /// `key=value` matches a label, `!text` excludes.
    func matches(_ query: String) -> Bool {
        for word in query.split(separator: " ").map(String.init) where !word.isEmpty {
            if word.hasPrefix("!") {
                let text = String(word.dropFirst())
                if !text.isEmpty, matchesWord(text) { return false }
            } else if !matchesWord(word) {
                return false
            }
        }
        return true
    }

    private func matchesWord(_ word: String) -> Bool {
        if let equals = word.firstIndex(of: "="), equals != word.startIndex {
            let key = String(word[..<equals])
            return labels[key]?.localizedCaseInsensitiveContains(String(word[word.index(after: equals)...])) == true
        }
        return [name, node ?? "", status, podIP ?? "", owner ?? "", namespace].contains { $0.localizedCaseInsensitiveContains(word) }
    }

    /// Warning event reasons per pod ("namespace/name"), from an EventList, most recent first,
    /// only events seen in the last `window` seconds.
    static func warnings(_ events: JSONValue, now: Date = .now, window: TimeInterval = 3600) -> [String: [String]] {
        var result: [String: [(Date, String)]] = [:]
        for event in events["items"]?.array ?? [] {
            guard event["type"]?.string == "Warning", event["involvedObject"]?["kind"]?.string == "Pod",
                  let name = event["involvedObject"]?["name"]?.string, let reason = event["reason"]?.string else { continue }
            let stamp = event["lastTimestamp"]?.string ?? event["eventTime"]?.string ?? event["metadata"]?["creationTimestamp"]?.string
            let date = stamp.flatMap { try? Date($0, strategy: .iso8601) } ?? now
            guard now.timeIntervalSince(date) <= window else { continue }
            let namespace = event["involvedObject"]?["namespace"]?.string ?? event["metadata"]?["namespace"]?.string ?? ""
            result["\(namespace)/\(name)", default: []].append((date, reason))
        }
        return result.mapValues { entries in
            var seen = Set<String>()
            return entries.sorted { $0.0 > $1.0 }.map(\.1).filter { seen.insert($0).inserted }
        }
    }

    /// The controller kind behind a pod: Deployment (through its ReplicaSet), StatefulSet, DaemonSet, Job, or nil.
    var controllerKind: String? {
        guard let kind = owner?.split(separator: "/").first.map(String.init) else { return nil }
        return kind == "ReplicaSet" ? "Deployment" : kind
    }

    /// The widget's status filter.
    enum Filter: String, CaseIterable, Sendable {
        case all, problems, running, pending, failed, completed

        var title: String {
            switch self {
            case .all: "All"
            case .problems: "Problems"
            case .running: "Running"
            case .pending: "Pending"
            case .failed: "Failed"
            case .completed: "Completed"
            }
        }
    }

    func passes(_ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .problems: ![.success, .neutral].contains(tone)
        case .running: phase == "Running"
        case .pending: phase == "Pending"
        case .failed: tone == .danger
        case .completed: phase == "Succeeded"
        }
    }

    enum Sort: String, CaseIterable, Sendable {
        case name, status, restarts, age

        var title: String { rawValue.capitalized }
    }

    static func sorted(_ pods: [PodSummary], by sort: Sort) -> [PodSummary] {
        switch sort {
        case .name: pods
        case .status: pods.sorted { (severity($0), $0.name) < (severity($1), $1.name) }
        case .restarts: pods.sorted { ($0.restarts, $1.name) > ($1.restarts, $0.name) }
        case .age: pods.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        }
    }

    /// Problems first: danger, warning, then the rest.
    private static func severity(_ pod: PodSummary) -> Int {
        switch pod.tone {
        case .danger: 0
        case .warning: 1
        case .success: 2
        default: 3
        }
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
            "age": .string(Self.age(since: created)),
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

/// Everything a Pods widget filters on, besides the server-side namespace and label selector.
struct PodQuery: Equatable, Sendable {
    var status: PodSummary.Filter = .all
    var search = ""
    /// Part of the node name.
    var node: String?
    /// Deployment, StatefulSet, DaemonSet, Job, or "none" for pods without a controller.
    var controller: String?
    var minRestarts: Int?
    /// Only pods younger than this.
    var maxAge: TimeInterval?
    /// nil: any; "any": pods with any recent Warning event; otherwise a Warning reason (BackOff, Unhealthy…).
    var event: String?

    static let eventReasons = ["BackOff", "Unhealthy", "FailedScheduling", "FailedMount", "FailedCreatePodSandBox", "OOMKilling", "Evicted", "Failed"]
    static let controllers = ["Deployment", "StatefulSet", "DaemonSet", "Job", "none"]

    func matches(_ pod: PodSummary, warnings: [String] = [], now: Date = .now) -> Bool {
        guard pod.passes(status), pod.matches(search) else { return false }
        if let node, !node.isEmpty, pod.node?.localizedCaseInsensitiveContains(node) != true { return false }
        if let controller {
            if controller == "none" ? pod.controllerKind != nil : pod.controllerKind != controller { return false }
        }
        if let minRestarts, pod.restarts < minRestarts { return false }
        if let maxAge, let created = pod.created, now.timeIntervalSince(created) > maxAge { return false }
        switch event {
        case nil: break
        case "any": if warnings.isEmpty { return false }
        case let reason?: if !warnings.contains(reason) { return false }
        }
        return true
    }
}
