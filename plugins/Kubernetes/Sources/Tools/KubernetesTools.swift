import DashKit
import Foundation

/// Single-purpose Kubernetes tools on the current context, kubectl-shaped: Claude asks for
/// exactly what it needs instead of composing raw API paths.
extension KubernetesIntegration {
    /// kubectl resource names → API paths (namespaced or not).
    static let kinds: [String: (path: String, namespaced: Bool)] = [
        "pods": ("/api/v1", true), "services": ("/api/v1", true), "configmaps": ("/api/v1", true), "secrets": ("/api/v1", true),
        "events": ("/api/v1", true), "persistentvolumeclaims": ("/api/v1", true), "serviceaccounts": ("/api/v1", true),
        "endpoints": ("/api/v1", true), "namespaces": ("/api/v1", false), "nodes": ("/api/v1", false), "persistentvolumes": ("/api/v1", false),
        "deployments": ("/apis/apps/v1", true), "statefulsets": ("/apis/apps/v1", true), "daemonsets": ("/apis/apps/v1", true),
        "replicasets": ("/apis/apps/v1", true), "jobs": ("/apis/batch/v1", true), "cronjobs": ("/apis/batch/v1", true),
        "horizontalpodautoscalers": ("/apis/autoscaling/v2", true), "ingresses": ("/apis/networking.k8s.io/v1", true),
        "httproutes": ("/apis/gateway.networking.k8s.io/v1", true), "poddisruptionbudgets": ("/apis/policy/v1", true),
    ]
    static let aliases = ["po": "pods", "svc": "services", "cm": "configmaps", "deploy": "deployments", "sts": "statefulsets", "ds": "daemonsets",
                          "rs": "replicasets", "cj": "cronjobs", "hpa": "horizontalpodautoscalers", "ing": "ingresses", "ns": "namespaces",
                          "no": "nodes", "pvc": "persistentvolumeclaims", "pv": "persistentvolumes", "sa": "serviceaccounts", "ep": "endpoints",
                          "pdb": "poddisruptionbudgets"]

    static func resolveKind(_ raw: String) throws -> (name: String, path: String, namespaced: Bool) {
        var kind = raw.lowercased().trimmingCharacters(in: .whitespaces)
        kind = aliases[kind] ?? kind
        if kinds[kind] == nil, kinds[kind + "s"] != nil { kind += "s" }
        guard let entry = kinds[kind] else { throw ToolError("Unknown kind \(raw). Known: \(kinds.keys.sorted().joined(separator: ", ")).") }
        return (kind, entry.path, entry.namespaced)
    }

    func collectionPath(_ kind: String, namespace: String?) throws -> String {
        let resolved = try Self.resolveKind(kind)
        guard resolved.namespaced, let namespace, namespace != "all" else { return "\(resolved.path)/\(resolved.name)" }
        guard Self.validNamespace(namespace) else { throw ToolError("\"\(namespace)\" is not a valid namespace name.") }
        return "\(resolved.path)/namespaces/\(namespace)/\(resolved.name)"
    }

    private func ns(_ value: String?) -> String { value?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? namespace }

    /// A compact line per object: name, namespace, age, and what matters for its kind.
    static func summary(_ item: JSONValue, kind: String) -> JSONValue {
        let metadata = item["metadata"]
        var row: [String: JSONValue] = ["name": metadata?["name"] ?? .null]
        if let namespace = metadata?["namespace"] { row["namespace"] = namespace }
        if let created = metadata?["creationTimestamp"] { row["created"] = created }
        let spec = item["spec"]
        let status = item["status"]
        switch kind {
        case "deployments", "statefulsets", "replicasets":
            row["ready"] = .string("\(status?["readyReplicas"]?.int ?? 0)/\(spec?["replicas"]?.int ?? 0)")
            row["images"] = .array((spec?["template"]?["spec"]?["containers"]?.array ?? []).compactMap { $0["image"] })
        case "daemonsets":
            row["ready"] = .string("\(status?["numberReady"]?.int ?? 0)/\(status?["desiredNumberScheduled"]?.int ?? 0)")
        case "services":
            row["type"] = spec?["type"] ?? .null
            row["clusterIP"] = spec?["clusterIP"] ?? .null
            row["ports"] = .array((spec?["ports"]?.array ?? []).map { .string("\($0["port"]?.int ?? 0)/\($0["protocol"]?.string ?? "TCP")") })
        case "jobs":
            row["succeeded"] = status?["succeeded"] ?? 0
            row["failed"] = status?["failed"] ?? 0
        case "cronjobs":
            row["schedule"] = spec?["schedule"] ?? .null
            row["lastSchedule"] = status?["lastScheduleTime"] ?? .null
        case "nodes":
            row["ready"] = .bool((status?["conditions"]?.array ?? []).contains { $0["type"]?.string == "Ready" && $0["status"]?.string == "True" })
            row["pressure"] = .array((status?["conditions"]?.array ?? []).filter { $0["type"]?.string != "Ready" && $0["status"]?.string == "True" }.compactMap { $0["type"] })
            row["allocatable"] = status?["allocatable"] ?? .null
        case "configmaps", "secrets":
            row["keys"] = .array(((item["data"]?.object ?? [:]).keys.sorted()).map { .string($0) })
        case "horizontalpodautoscalers":
            row["replicas"] = .string("\(status?["currentReplicas"]?.int ?? 0) (min \(spec?["minReplicas"]?.int ?? 1), max \(spec?["maxReplicas"]?.int ?? 0))")
        case "events":
            row["type"] = item["type"] ?? .null
            row["reason"] = item["reason"] ?? .null
            row["object"] = .string("\(item["involvedObject"]?["kind"]?.string ?? "")/\(item["involvedObject"]?["name"]?.string ?? "")")
            row["message"] = item["message"] ?? .null
            row["count"] = item["count"] ?? 1
            row["lastSeen"] = item["lastTimestamp"] ?? item["eventTime"] ?? .null
        default:
            if let phase = status?["phase"] { row["phase"] = phase }
        }
        return .object(row)
    }

    private struct ListInput: Decodable { let kind: String; let namespace: String?; let labelSelector: String?; let fieldSelector: String? }
    private struct ObjectInput: Decodable { let kind: String; let name: String; let namespace: String? }
    private struct LogsInput: Decodable { let pod: String; let namespace: String?; let container: String?; let previous: Bool?; let tail: Int?; let sinceSeconds: Int? }
    private struct EventsInput: Decodable { let namespace: String?; let object: String?; let warningsOnly: Bool? }
    private struct NamespaceInput: Decodable { let namespace: String? }
    private struct DeploymentInput: Decodable { let name: String; let namespace: String? }
    private struct ScaleInput: Decodable { let name: String; let namespace: String?; let replicas: Int }

    var granularTools: [DashiiTool] {
        let namespaceProperty = JSONSchema.string("Namespace; default: the one set in Settings. \"all\" for every namespace (lists only).")
        return [
            DashiiTool(name: "k8s_contexts", description: "The kubeconfig's contexts (cluster, namespace, auth) and which one Dash uses. Read-only.") { [weak self] _ in
                guard let self else { return nil }
                return exports
            },
            DashiiTool(name: "k8s_namespaces", description: "Namespaces on the current context with their status and labels. Read-only.") { [weak self] _ in
                guard let self else { return nil }
                let list = try await requireConnection().get("/api/v1/namespaces", service: "Kubernetes")
                return .array((list["items"]?.array ?? []).map { ["name": $0["metadata"]?["name"] ?? .null, "status": $0["status"]?["phase"] ?? .null,
                                                                  "labels": $0["metadata"]?["labels"] ?? .null] })
            },
            DashiiTool(name: "k8s_list", description: "List objects of a kind (kubectl get): deployments, services, configmaps (keys only), secrets (keys only, never values), jobs, cronjobs, statefulsets, daemonsets, hpa, ingresses, httproutes, nodes, events, pvc… with a compact line each. Read-only.",
                       properties: ["kind": JSONSchema.string("Kind or kubectl short name (deploy, svc, cm, hpa…)."), "namespace": namespaceProperty,
                                    "labelSelector": JSONSchema.string("e.g. app=web"), "fieldSelector": JSONSchema.string("e.g. status.phase!=Running")],
                       required: ["kind"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ListInput.self)
                let kind = try Self.resolveKind(request.kind).name
                var path = try collectionPath(kind, namespace: ns(request.namespace))
                var query: [String] = ["limit=500"]
                if let label = request.labelSelector { query.append("labelSelector=\(label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? label)") }
                if let field = request.fieldSelector { query.append("fieldSelector=\(field.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? field)") }
                path += "?" + query.joined(separator: "&")
                let list = try await requireConnection().get(path, service: "Kubernetes")
                return .array((list["items"]?.array ?? []).map { Self.summary($0, kind: kind) })
            },
            DashiiTool(name: "k8s_describe", description: "One object in full (kubectl describe): its spec and status, plus the events about it. Secret values are removed. Read-only.",
                       properties: ["kind": JSONSchema.string("Kind or short name."), "name": JSONSchema.string("Object name."), "namespace": namespaceProperty],
                       required: ["kind", "name"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ObjectInput.self)
                let resolved = try Self.resolveKind(request.kind)
                let namespace = ns(request.namespace)
                let connection = try requireConnection()
                var object = try await connection.get(try collectionPath(resolved.name, namespace: namespace) + "/\(request.name)", service: "Kubernetes")
                if resolved.name == "secrets", case .object(var fields) = object {
                    fields["data"] = .object((fields["data"]?.object ?? [:]).mapValues { _ in "<redacted>" })
                    fields["stringData"] = nil
                    object = .object(fields)
                }
                if case .object(var fields) = object, case .object(var metadata)? = fields["metadata"] {
                    metadata["managedFields"] = nil
                    fields["metadata"] = .object(metadata)
                    object = .object(fields)
                }
                var events: JSONValue = []
                if resolved.namespaced {
                    let selector = "involvedObject.name=\(request.name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    let list = try? await connection.get("/api/v1/namespaces/\(namespace)/events?fieldSelector=\(selector)", service: "Kubernetes")
                    events = .array((list?["items"]?.array ?? []).map { Self.summary($0, kind: "events") })
                }
                return ["object": object, "events": events]
            },
            DashiiTool(name: "k8s_logs", description: "A pod's logs (kubectl logs): container, the run before the last restart (previous), last N lines or since N seconds, with timestamps. Read-only.",
                       properties: ["pod": JSONSchema.string("Pod name."), "namespace": namespaceProperty, "container": JSONSchema.string("Container name."),
                                    "previous": JSONSchema.boolean("The previous run's logs."), "tail": JSONSchema.integer("Last N lines (default 300)."),
                                    "sinceSeconds": JSONSchema.integer("Only this many seconds back.")],
                       required: ["pod"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(LogsInput.self)
                var query = ["timestamps=true", "tailLines=\(min(request.tail ?? 300, 5000))"]
                if let container = request.container { query.append("container=\(container)") }
                if request.previous == true { query.append("previous=true") }
                if let since = request.sinceSeconds { query.append("sinceSeconds=\(since)") }
                return try await Self.get("/api/v1/namespaces/\(ns(request.namespace))/pods/\(request.pod)/log?" + query.joined(separator: "&"), connection: try requireConnection())
            },
            DashiiTool(name: "k8s_events", description: "Events in a namespace, newest first (kubectl get events): warnings only by default, or about one object (Kind/name). Read-only.",
                       properties: ["namespace": namespaceProperty, "object": JSONSchema.string("Kind/name, e.g. Pod/web-1."),
                                    "warningsOnly": JSONSchema.boolean("Only Warning events (default true).")]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(EventsInput.self)
                let list = try await requireConnection().get(try collectionPath("events", namespace: ns(request.namespace)), service: "Kubernetes")
                let rows = (list["items"]?.array ?? []).map { Self.summary($0, kind: "events") }.filter { row in
                    (!(request.warningsOnly ?? true) || row["type"]?.string == "Warning") && (request.object == nil || row["object"]?.string == request.object)
                }
                return .array(Array(rows.sorted { ($0["lastSeen"]?.string ?? "") > ($1["lastSeen"]?.string ?? "") }.prefix(100)))
            },
            DashiiTool(name: "k8s_top_pods", description: "CPU and memory each pod's containers use now (kubectl top pods; needs metrics-server). Read-only.",
                       properties: ["namespace": namespaceProperty]) { [weak self] input in
                guard let self else { return nil }
                let namespace = ns(try input.toolInput(NamespaceInput.self).namespace)
                let path = namespace == "all" ? "/apis/metrics.k8s.io/v1beta1/pods" : "/apis/metrics.k8s.io/v1beta1/namespaces/\(namespace)/pods"
                let list = try await requireConnection().get(path, service: "Kubernetes")
                return .array((list["items"]?.array ?? []).map { pod in
                    ["pod": pod["metadata"]?["name"] ?? .null, "namespace": pod["metadata"]?["namespace"] ?? .null,
                     "containers": .array((pod["containers"]?.array ?? []).map { ["name": $0["name"] ?? .null, "cpu": $0["usage"]?["cpu"] ?? .null, "memory": $0["usage"]?["memory"] ?? .null] })]
                })
            },
            DashiiTool(name: "k8s_rollout_status", description: "Whether a deployment's rollout finished (kubectl rollout status): updated, ready and available replicas, and its conditions. Read-only.",
                       properties: ["name": JSONSchema.string("Deployment name."), "namespace": namespaceProperty], required: ["name"]) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(DeploymentInput.self)
                let deployment = try await requireConnection().get("/apis/apps/v1/namespaces/\(ns(request.namespace))/deployments/\(request.name)", service: "Kubernetes")
                let spec = deployment["spec"]
                let status = deployment["status"]
                let desired = spec?["replicas"]?.int ?? 1
                let done = (status?["updatedReplicas"]?.int ?? 0) == desired && (status?["availableReplicas"]?.int ?? 0) == desired
                    && (status?["observedGeneration"]?.int ?? 0) >= (deployment["metadata"]?["generation"]?.int ?? 0)
                return ["done": .bool(done), "desired": .number(Double(desired)), "updated": status?["updatedReplicas"] ?? 0,
                        "ready": status?["readyReplicas"] ?? 0, "available": status?["availableReplicas"] ?? 0, "conditions": status?["conditions"] ?? []]
            },
            DashiiTool(name: "k8s_rollout_restart", description: "Restart a deployment's pods (kubectl rollout restart).",
                       properties: ["name": JSONSchema.string("Deployment name."), "namespace": namespaceProperty], required: ["name"], requiresApproval: true, writesRemotely: true) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(DeploymentInput.self)
                try await patch("/apis/apps/v1/namespaces/\(ns(request.namespace))/deployments/\(request.name)",
                                ["spec": ["template": ["metadata": ["annotations": ["kubectl.kubernetes.io/restartedAt": .string(ISO8601DateFormatter().string(from: .now))]]]]],
                                contentType: "application/strategic-merge-patch+json")
                return "restarted"
            },
            DashiiTool(name: "k8s_scale", description: "Set a deployment's replica count (kubectl scale).",
                       properties: ["name": JSONSchema.string("Deployment name."), "namespace": namespaceProperty, "replicas": JSONSchema.integer("Replicas, 0-50.")],
                       required: ["name", "replicas"], requiresApproval: true, writesRemotely: true) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(ScaleInput.self)
                guard (0...50).contains(request.replicas) else { throw ToolError("Replicas must be between 0 and 50.") }
                try await patch("/apis/apps/v1/namespaces/\(ns(request.namespace))/deployments/\(request.name)",
                                ["spec": ["replicas": .number(Double(request.replicas))]], contentType: "application/merge-patch+json")
                return ["replicas": .number(Double(request.replicas))]
            },
        ]
    }

    private func patch(_ path: String, _ body: JSONValue, contentType: String) async throws {
        let connection = try requireConnection()
        guard let url = connection.url(path) else { throw ToolError("Bad path \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.jsonString().utf8)
        _ = try await connection.send(request, service: "Kubernetes")
    }
}
