import DashKit
import Foundation

/// Dashii's raw Kubernetes tools: read any API path, list pods.
extension KubernetesIntegration {
    private struct GetInput: Decodable { let path: String }
    private struct PodsInput: Decodable {
        let namespace: String?
        let labelSelector: String?
        let fieldSelector: String?
    }

    static let maxCharacters = 100_000

    /// Rejects anything that isn't a plain read: full URLs, `..`, watches, follows and streaming subresources.
    static func checkReadOnly(_ path: String) throws {
        guard path.hasPrefix("/"), !path.contains("://"), !path.hasPrefix("//") else {
            throw ToolError("path must be an API path starting with /, e.g. /api/v1/namespaces/default/pods.")
        }
        let parts = path.split(separator: "?", maxSplits: 1)
        let segments = parts[0].split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        if segments.contains("..") || segments.contains(".") { throw ToolError("path must not contain . or .. segments.") }
        let streaming: Set<String> = ["exec", "attach", "portforward", "proxy"]
        if let segment = segments.first(where: { streaming.contains($0) }) {
            throw ToolError("\(segment) is not a read-only request; k8s_get only reads resources.")
        }
        if parts.count == 2 {
            for item in parts[1].split(separator: "&") {
                let pair = item.split(separator: "=", maxSplits: 1).map { $0.removingPercentEncoding ?? String($0) }
                if ["watch", "follow"].contains(pair[0].lowercased()), pair.count == 1 || !["false", "0"].contains(pair[1].lowercased()) {
                    throw ToolError("\(pair[0]) requests stream forever; ask for a plain list instead.")
                }
            }
        }
    }

    static func validNamespace(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 63 && text.allSatisfy { ($0.isASCII && ($0.isLowercase || $0.isNumber)) || $0 == "-" }
            && text.first != "-" && text.last != "-"
    }

    func requireConnection() throws -> IntegrationConnection {
        guard let connection else { throw ToolError(blockingProblem ?? "Set up Kubernetes in Settings › Kubernetes.") }
        return connection
    }

    var tools: [DashiiTool] {
        [
            DashiiTool(
                name: "k8s_get",
                description: "Read any Kubernetes API path on the current context (GET only), e.g. /api/v1/namespaces/default/pods, /apis/apps/v1/namespaces/prod/deployments/web, /api/v1/namespaces/default/pods/web-1/log?tailLines=100 or /api/v1/nodes. Watches, exec, attach, port-forward and proxy are refused. Responses are cut at 100,000 characters.",
                properties: ["path": JSONSchema.string("API path starting with /, with an optional query string.")], required: ["path"]
            ) { [weak self] input in
                guard let self else { throw ToolError("Kubernetes is not loaded.") }
                let path = try input.toolInput(GetInput.self).path.trimmingCharacters(in: .whitespaces)
                try Self.checkReadOnly(path)
                return try await Self.get(path, connection: try requireConnection())
            },
            DashiiTool(
                name: "k8s_list_pods",
                description: "List pods on the current Kubernetes context with phase, kubectl-style status (CrashLoopBackOff, ImagePullBackOff…), ready containers, restarts and node. Defaults to the configured namespace; use \"all\" for every namespace.",
                properties: [
                    "namespace": JSONSchema.string("Namespace, or \"all\". Default: the namespace set in Settings."),
                    "labelSelector": JSONSchema.string("Label selector, e.g. app=web,tier!=cache."),
                    "fieldSelector": JSONSchema.string("Field selector, e.g. status.phase!=Running or spec.nodeName=node-1."),
                ]
            ) { [weak self] input in
                guard let self else { throw ToolError("Kubernetes is not loaded.") }
                let request = try input.toolInput(PodsInput.self)
                let namespace = request.namespace?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? self.namespace
                let all = namespace == "all" || namespace == "*"
                guard all || Self.validNamespace(namespace) else { throw ToolError("\"\(namespace)\" is not a valid namespace name.") }
                let connection = try requireConnection()
                let list = try await connection.get(
                    PodSummary.path(namespace: all ? nil : namespace, labelSelector: request.labelSelector, fieldSelector: request.fieldSelector, limit: 500),
                    service: "Kubernetes")
                let pods = PodSummary.list(list)
                var result: [String: JSONValue] = [
                    "context": activeContext.map(JSONValue.string) ?? .null, "namespace": .string(all ? "all" : namespace),
                    "count": .number(Double(pods.count)), "pods": .array(pods.map(\.json)),
                ]
                if let next = list["metadata"]?["continue"]?.string, !next.isEmpty { result["truncated"] = "More than 500 pods; narrow with a selector." }
                return .object(result)
            },
        ] + granularTools
    }

    /// GETs a path and returns JSON, or text cut at `maxCharacters`.
    static func get(_ path: String, connection: IntegrationConnection) async throws -> JSONValue {
        guard let url = connection.url(path) else { throw ToolError("Bad path \(path)") }
        let (data, _) = try await connection.send(URLRequest(url: url), service: "Kubernetes")
        let text = String(decoding: data, as: UTF8.self)
        if text.count > maxCharacters { return .string(String(text.prefix(maxCharacters)) + "\n[truncated]") }
        return (try? JSONValue.parse(data)) ?? .string(text)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
