import DashKit
import Foundation

/// Dashii and agents get the readers: they answer from what the fetchers stored in Dash. Nothing
/// they get calls the cluster; `data_fetch k8s.<what>` does. Besides the readers: the kubeconfig's
/// contexts (read locally) and the two writes, which only the user approves and never reach Dashii.
extension KubernetesIntegration {
    var tools: [DashiiTool] { [contextsTool] + readers + writeTools }

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
            throw ToolError("\(segment) is not a read-only request; k8s.api only reads resources.")
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
