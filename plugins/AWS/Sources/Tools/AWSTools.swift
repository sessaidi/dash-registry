import DashKit
import Foundation

/// Dashii's AWS tools: who Dash is (as last checked), and the readers of what Dash fetched.
/// None of them calls AWS.
extension AWSIntegration {
    var tools: [DashiiTool] {
        [
            DashiiTool(name: "aws_whoami", description: "The AWS identity (ARN), profile and region Dash uses, as checked when Dash started or at Settings › AWS › Check (checked_at).") { [weak self] _ in
                guard let self else { return nil }
                return whoami
            },
        ] + readers
    }

    /// The identity from the last check; no request.
    var whoami: JSONValue {
        var answer: JSONValue = ["arn": identity.map(JSONValue.string) ?? .null, "profile": .string(profileName), "region": .string(region),
                                 "checked_at": checkedAt.map { .string($0.formatted(.iso8601)) } ?? .null]
        if identity == nil {
            answer = answer.merging(["error": .string(lastError ?? "Not checked yet."), "hint": "The user can check again in Settings › AWS."])
        }
        return answer
    }

    /// Action-name prefixes that only read. AWS query and JSON APIs are POSTs even for reads,
    /// so the action decides.
    nonisolated static let readOnlyPrefixes = ["Describe", "List", "Get", "BatchGet", "Search", "Lookup", "Query", "Scan", "Filter", "Select"]

    /// Throws unless the call only reads: a GET, or a POST whose action (X-Amz-Target or the
    /// Action= form field) is a Describe/List/Get-style one. Dash never changes AWS.
    nonisolated static func requireReadOnly(method: String, url: URL, body: String?, target: String?) throws {
        if method.uppercased() == "GET" { return }
        let fields = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            + (URLComponents(string: "?" + (body ?? ""))?.queryItems ?? [])
        let action = target.map { $0.split(separator: ".").last.map(String.init) ?? $0 } ?? fields.first { $0.name == "Action" }?.value
        guard let action, readOnlyPrefixes.contains(where: { action.hasPrefix($0) }) else {
            throw ToolError("aws.api is read-only: \(action ?? "this call") could change AWS. Only Describe/List/Get-style actions run.")
        }
    }
}
