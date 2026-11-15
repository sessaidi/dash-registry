import DashKit
import Foundation

/// Dashii's AWS tools: who Dash is, and read-only signed API calls.
extension AWSIntegration {
    private struct APIInput: Decodable {
        let method: String?
        let url: String
        let body: String?
        let content_type: String?
        let target: String?
    }

    var tools: [DashiiTool] {
        [
            DashiiTool(name: "aws_whoami", description: "The AWS identity (ARN), profile and region Dash uses.") { [weak self] _ in
                guard let self else { return nil }
                return ["arn": .string(try await callerIdentity()), "profile": .string(profileName), "region": .string(region)]
            },
            DashiiTool(
                name: "aws_api",
                description: """
                    Call an AWS API as the user, signed with SigV4. Give the full https URL on *.amazonaws.com \
                    (the service and region come from the host). Query APIs: POST form body "Action=DescribeInstances&Version=2016-11-15". \
                    JSON APIs: content_type application/x-amz-json-1.1 plus target, e.g. "Logs_20140328.DescribeLogGroups". \
                    Read-only: only Describe/List/Get-style actions (and GET requests) run; anything that changes AWS is refused.
                    """,
                properties: [
                    "method": JSONSchema.string("HTTP method (default POST).", enum: ["GET", "POST"]),
                    "url": JSONSchema.string("Full URL, e.g. https://ec2.eu-west-1.amazonaws.com/"),
                    "body": JSONSchema.string("Request body (form or JSON text)."),
                    "content_type": JSONSchema.string("Content-Type (default application/x-www-form-urlencoded; charset=utf-8)."),
                    "target": JSONSchema.string("X-Amz-Target for JSON-protocol services."),
                ],
                required: ["url"]
            ) { [weak self] input in
                guard let self else { return nil }
                let call = try input.toolInput(APIInput.self)
                guard let url = URL(string: call.url) else { throw ToolError("Bad URL \(call.url)") }
                try Self.requireReadOnly(method: call.method ?? "POST", url: url, body: call.body, target: call.target)
                var request = URLRequest(url: url)
                request.httpMethod = call.method ?? "POST"
                if let body = call.body {
                    request.httpBody = Data(body.utf8)
                    request.setValue(call.content_type ?? "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
                }
                if let target = call.target { request.setValue(target, forHTTPHeaderField: "X-Amz-Target") }
                let (data, _) = try await send(request)
                let text = String(decoding: data, as: UTF8.self)
                return text.count > Self.maxToolCharacters
                    ? .string(String(text.prefix(Self.maxToolCharacters)) + "\n[truncated]") : ((try? JSONValue.parse(data)) ?? .string(text))
            },
        ]
    }

    /// Action-name prefixes that only read. AWS query and JSON APIs are POSTs even for reads,
    /// so the action decides.
    static let readOnlyPrefixes = ["Describe", "List", "Get", "BatchGet", "Search", "Lookup", "Query", "Scan", "Filter", "Select"]

    /// Throws unless the call only reads: a GET, or a POST whose action (X-Amz-Target or the
    /// Action= form field) is a Describe/List/Get-style one. Claude never changes AWS.
    static func requireReadOnly(method: String, url: URL, body: String?, target: String?) throws {
        if method.uppercased() == "GET" { return }
        let fields = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            + (URLComponents(string: "?" + (body ?? ""))?.queryItems ?? [])
        let action = target.map { $0.split(separator: ".").last.map(String.init) ?? $0 } ?? fields.first { $0.name == "Action" }?.value
        guard let action, readOnlyPrefixes.contains(where: { action.hasPrefix($0) }) else {
            throw ToolError("aws_api is read-only: \(action ?? "this call") could change AWS. Only Describe/List/Get-style actions run.")
        }
    }
}
