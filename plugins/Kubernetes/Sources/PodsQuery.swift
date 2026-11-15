import DashKit
import Foundation

/// Pods for DashQL: the `pods` dataset and the Pods widget's query bar.
extension PodSummary {
    static let queryFields: [QueryDataset.Field] = [
        .init("name", "string", "Pod name"),
        .init("namespace", "string", "Namespace", aliases: ["ns"]),
        .init("status", "string", "kubectl's STATUS: Running, CrashLoopBackOff, ImagePullBackOff, Pending, Completed…"),
        .init("phase", "string", "Pending, Running, Succeeded, Failed, Unknown"),
        .init("ready", "number", "Ready containers"),
        .init("total", "number", "Containers"),
        .init("restarts", "number", "Restarts across containers"),
        .init("node", "string", "Node it runs on"),
        .init("created", "date", "When it was created", aliases: ["age", "started"]),
        .init("ip", "string", "Pod IP"),
        .init("owner", "string", "Controlling object, e.g. ReplicaSet/api-7d9f8c6b5", aliases: ["controller"]),
        .init("app", "string", "The app label (app.kubernetes.io/name or app)"),
        .init("labels", "list", "Labels as key=value"),
        .init("containers", "list", "Container names"),
        .init("healthy", "bool", "Running and ready, or completed"),
        .init("warnings", "list", "Recent Warning event reasons, when the widget fetches events"),
        .init("context", "string", "Kubeconfig context"),
    ]

    func queryRow(context: String? = nil, warnings: [String] = []) -> JSONValue {
        [
            "name": .string(name), "namespace": .string(namespace), "status": .string(status), "phase": .string(phase),
            "ready": .number(Double(ready)), "total": .number(Double(total)), "restarts": .number(Double(restarts)),
            "node": node.queryValue, "created": created.queryValue, "ip": podIP.queryValue, "owner": owner.queryValue,
            "app": (labels["app.kubernetes.io/name"] ?? labels["app"]).queryValue,
            "labels": .array(labels.sorted { $0.key < $1.key }.map { .string("\($0.key)=\($0.value)") }),
            "containers": .array(containers.map(JSONValue.string)),
            "healthy": .bool(phase == "Succeeded" || (phase == "Running" && ready == total && status == "Running")),
            "warnings": .array(warnings.map(JSONValue.string)), "context": context.queryValue,
        ]
    }
}

extension PodsFeature {
    /// Every pod Dash has loaded: the configured namespace's, and each Pods widget's view.
    var datasets: [QueryDataset] {
        [QueryDataset(name: "pods", summary: "Kubernetes pods Dash has loaded (the Pods widgets' contexts and namespaces), refreshed every 30 seconds.",
                      fields: PodSummary.queryFields) { [weak self] _ in
            guard let self else { return [] }
            var rows: [String: JSONValue] = [:]
            for pod in pods { rows["\(context ?? "")|\(pod.id)"] = pod.queryRow(context: context) }
            for (key, browse) in browsing {
                for pod in browse.pods { rows["\(key.context ?? context ?? "")|\(pod.id)"] = pod.queryRow(context: key.context ?? context, warnings: browse.warnings[pod.id] ?? []) }
            }
            return rows.sorted { $0.key < $1.key }.map(\.value)
        }]
    }
}
