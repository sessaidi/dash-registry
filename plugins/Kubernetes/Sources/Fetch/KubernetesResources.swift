import DashKit
import Foundation

/// Something Dash can fetch from the current Kubernetes context and read back: the fetcher
/// `k8s.<what>` calls the cluster and stores the answer; the reader (same input, the old live
/// tool's name) returns it with its freshness, or says to fetch first.
struct KubernetesResource {
    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    let properties: [String: JSONValue]
    var required: [String] = []
    /// Answers to a query (lists, logs, raw paths): kept a day, then dropped.
    var queryShaped = false
    /// How long a stored answer counts as fresh: pods move in seconds, namespaces rarely.
    var freshFor: Duration = .seconds(5 * 60)
    /// The reader's name when it isn't `k8s_<what>`.
    var reader: String?
    /// Calls the cluster and returns the answer that gets stored. The input is checked, with the
    /// namespace filled in.
    let load: @MainActor (KubernetesIntegration, JSONValue) async throws -> JSONValue

    var fetcherName: String { "k8s." + what }
    var readerName: String { reader ?? "k8s_" + what }
    var kind: String { "k8s." + what }
}

extension KubernetesIntegration {
    /// Everything the Kubernetes tools used to ask the cluster live, now fetched into Dash and read there.
    var resources: [KubernetesResource] {
        let namespace = JSONSchema.string("Namespace; default: the one set in Settings. \"all\" for every namespace (lists only).")
        let minute: Duration = .seconds(60)
        func text(_ input: JSONValue, _ name: String) -> String { input[name]?.string ?? "" }
        return [
            KubernetesResource(what: "pods", summary: "Pods on the current context with phase, kubectl-style status (CrashLoopBackOff, ImagePullBackOff…), ready containers, restarts and node. Defaults to the configured namespace; \"all\" for every namespace.",
                               properties: ["namespace": namespace, "labelSelector": JSONSchema.string("Label selector, e.g. app=web,tier!=cache."),
                                            "fieldSelector": JSONSchema.string("Field selector, e.g. status.phase!=Running or spec.nodeName=node-1.")],
                               queryShaped: true, freshFor: minute, reader: "k8s_list_pods") { k8s, input in
                let all = Self.isAll(text(input, "namespace"))
                let list = try await k8s.requireConnection().get(
                    PodSummary.path(namespace: all ? nil : text(input, "namespace"), labelSelector: input["labelSelector"]?.string,
                                    fieldSelector: input["fieldSelector"]?.string, limit: 500),
                    service: "Kubernetes")
                let pods = PodSummary.list(list)
                var result: [String: JSONValue] = [
                    "context": k8s.activeContext.map(JSONValue.string) ?? .null, "namespace": .string(all ? "all" : text(input, "namespace")),
                    "count": .number(Double(pods.count)), "pods": .array(pods.map(\.json)),
                ]
                if let next = list["metadata"]?["continue"]?.string, !next.isEmpty { result["truncated"] = "More than 500 pods; narrow with a selector." }
                return .object(result)
            },
            KubernetesResource(what: "namespaces", summary: "Namespaces on the current context with their status and labels.",
                               properties: [:], freshFor: .seconds(3600)) { k8s, _ in
                let list = try await k8s.requireConnection().get("/api/v1/namespaces", service: "Kubernetes")
                return .array((list["items"]?.array ?? []).map { ["name": $0["metadata"]?["name"] ?? .null, "status": $0["status"]?["phase"] ?? .null,
                                                                  "labels": $0["metadata"]?["labels"] ?? .null] })
            },
            KubernetesResource(what: "list", summary: "Objects of a kind (kubectl get): deployments, services, configmaps (keys only), secrets (keys only, never values), jobs, cronjobs, statefulsets, daemonsets, hpa, ingresses, httproutes, nodes, events, pvc… with a compact line each.",
                               properties: ["kind": JSONSchema.string("Kind or kubectl short name (deploy, svc, cm, hpa…)."), "namespace": namespace,
                                            "labelSelector": JSONSchema.string("e.g. app=web"), "fieldSelector": JSONSchema.string("e.g. status.phase!=Running")],
                               required: ["kind"], queryShaped: true) { k8s, input in
                let kind = text(input, "kind")
                var query: [String] = ["limit=500"]
                if let label = input["labelSelector"]?.string { query.append("labelSelector=\(label.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? label)") }
                if let field = input["fieldSelector"]?.string { query.append("fieldSelector=\(field.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? field)") }
                let path = try k8s.collectionPath(kind, namespace: text(input, "namespace")) + "?" + query.joined(separator: "&")
                let list = try await k8s.requireConnection().get(path, service: "Kubernetes")
                return .array((list["items"]?.array ?? []).map { Self.summary($0, kind: kind) })
            },
            KubernetesResource(what: "describe", summary: "One object in full (kubectl describe): its spec and status, plus the events about it. Secret values are removed.",
                               properties: ["kind": JSONSchema.string("Kind or short name."), "name": JSONSchema.string("Object name."), "namespace": namespace],
                               required: ["kind", "name"]) { k8s, input in
                let resolved = try Self.resolveKind(text(input, "kind"))
                let name = text(input, "name"), space = text(input, "namespace")
                let connection = try k8s.requireConnection()
                var object = try await connection.get(try k8s.collectionPath(resolved.name, namespace: space) + "/\(name)", service: "Kubernetes")
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
                    let selector = "involvedObject.name=\(name)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                    let list = try? await connection.get("/api/v1/namespaces/\(space)/events?fieldSelector=\(selector)", service: "Kubernetes")
                    events = .array((list?["items"]?.array ?? []).map { Self.summary($0, kind: "events") })
                }
                return ["object": object, "events": events]
            },
            KubernetesResource(what: "logs", summary: "A pod's logs (kubectl logs): container, the run before the last restart (previous), last N lines or since N seconds, with timestamps.",
                               properties: ["pod": JSONSchema.string("Pod name."), "namespace": namespace, "container": JSONSchema.string("Container name."),
                                            "previous": JSONSchema.boolean("The previous run's logs."), "tail": JSONSchema.integer("Last N lines (default 300)."),
                                            "sinceSeconds": JSONSchema.integer("Only this many seconds back.")],
                               required: ["pod"], queryShaped: true, freshFor: .seconds(120)) { k8s, input in
                var query = ["timestamps=true", "tailLines=\(min(max(input["tail"]?.int ?? 300, 1), 5000))"]
                if let container = input["container"]?.string { query.append("container=\(container)") }
                if input["previous"]?.bool == true { query.append("previous=true") }
                if let since = input["sinceSeconds"]?.int { query.append("sinceSeconds=\(max(since, 1))") }
                return try await Self.get("/api/v1/namespaces/\(text(input, "namespace"))/pods/\(text(input, "pod"))/log?" + query.joined(separator: "&"),
                                          connection: try k8s.requireConnection())
            },
            KubernetesResource(what: "events", summary: "Events in a namespace, newest first (kubectl get events): warnings only by default, or about one object (Kind/name).",
                               properties: ["namespace": namespace, "object": JSONSchema.string("Kind/name, e.g. Pod/web-1."),
                                            "warningsOnly": JSONSchema.boolean("Only Warning events (default true).")],
                               queryShaped: true, freshFor: .seconds(120)) { k8s, input in
                let list = try await k8s.requireConnection().get(try k8s.collectionPath("events", namespace: text(input, "namespace")), service: "Kubernetes")
                let warningsOnly = input["warningsOnly"]?.bool ?? true, object = input["object"]?.string
                let rows = (list["items"]?.array ?? []).map { Self.summary($0, kind: "events") }.filter { row in
                    (!warningsOnly || row["type"]?.string == "Warning") && (object == nil || row["object"]?.string == object)
                }
                return .array(Array(rows.sorted { ($0["lastSeen"]?.string ?? "") > ($1["lastSeen"]?.string ?? "") }.prefix(100)))
            },
            KubernetesResource(what: "top_pods", summary: "CPU and memory each pod's containers use (kubectl top pods; needs metrics-server).",
                               properties: ["namespace": namespace], queryShaped: true, freshFor: minute) { k8s, input in
                let space = text(input, "namespace")
                let path = Self.isAll(space) ? "/apis/metrics.k8s.io/v1beta1/pods" : "/apis/metrics.k8s.io/v1beta1/namespaces/\(space)/pods"
                let list = try await k8s.requireConnection().get(path, service: "Kubernetes")
                return .array((list["items"]?.array ?? []).map { pod in
                    ["pod": pod["metadata"]?["name"] ?? .null, "namespace": pod["metadata"]?["namespace"] ?? .null,
                     "containers": .array((pod["containers"]?.array ?? []).map { ["name": $0["name"] ?? .null, "cpu": $0["usage"]?["cpu"] ?? .null, "memory": $0["usage"]?["memory"] ?? .null] })]
                })
            },
            KubernetesResource(what: "rollout_status", summary: "Whether a deployment's rollout finished (kubectl rollout status): updated, ready and available replicas, and its conditions.",
                               properties: ["name": JSONSchema.string("Deployment name."), "namespace": namespace], required: ["name"], freshFor: minute) { k8s, input in
                let deployment = try await k8s.requireConnection().get("/apis/apps/v1/namespaces/\(text(input, "namespace"))/deployments/\(text(input, "name"))", service: "Kubernetes")
                let spec = deployment["spec"]
                let status = deployment["status"]
                let desired = spec?["replicas"]?.int ?? 1
                let done = (status?["updatedReplicas"]?.int ?? 0) == desired && (status?["availableReplicas"]?.int ?? 0) == desired
                    && (status?["observedGeneration"]?.int ?? 0) >= (deployment["metadata"]?["generation"]?.int ?? 0)
                return ["done": .bool(done), "desired": .number(Double(desired)), "updated": status?["updatedReplicas"] ?? 0,
                        "ready": status?["readyReplicas"] ?? 0, "available": status?["availableReplicas"] ?? 0, "conditions": status?["conditions"] ?? []]
            },
            KubernetesResource(what: "api", summary: "Any Kubernetes API path on the current context (GET only) when no other fetcher fits, e.g. /api/v1/nodes or /apis/apps/v1/namespaces/prod/deployments/web. Watches, exec, attach, port-forward and proxy are refused; the answer is stored cut to 200 KB.",
                               properties: ["path": JSONSchema.string("API path starting with /, with an optional query string.")], required: ["path"],
                               queryShaped: true, reader: "k8s_api_read") { k8s, input in
                try await Self.get(text(input, "path"), connection: try k8s.requireConnection())
            },
        ]
    }

    nonisolated static func isAll(_ namespace: String) -> Bool { namespace == "all" || namespace == "*" }

    /// A pod, container or object name that can't leave its path segment.
    nonisolated static func validName(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 253 && text != "." && text != ".."
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._:".contains($0)) }
    }
}
