import DashKit
import Foundation

/// kubectl's vocabulary on the current context: kinds and short names, compact summaries, and the
/// tools that don't read through the store.
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

    private struct DeploymentInput: Decodable { let name: String; let namespace: String? }
    private struct ScaleInput: Decodable { let name: String; let namespace: String?; let replicas: Int }

    /// The kubeconfig's contexts: read from the file Dash already loaded, no request.
    var contextsTool: DashiiTool {
        DashiiTool(name: "k8s_contexts", description: "The kubeconfig's contexts (cluster, namespace, auth) and which one Dash uses. Read-only.") { [weak self] _ in
            guard let self else { return nil }
            return exports
        }
    }

    /// What changes a cluster: the user approves each call, and Dashii and agents never get them.
    var writeTools: [DashiiTool] {
        let namespaceProperty = JSONSchema.string("Namespace; default: the one set in Settings.")
        return [
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
