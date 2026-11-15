import DashKit
import Foundation

/// Acme's tools: reads only, so Dashii and read-only agents may use them.
@MainActor
enum AcmeTools {
    static let statuses = ["todo", "doing", "done"]

    static func tools(integration: AcmeIntegration) -> [DashiiTool] {
        [
            DashiiTool(name: "acme_get", description: "GET an Acme API path and return the JSON. Read-only.",
                       properties: ["path": JSONSchema.string("API path, e.g. /me or /tickets?status=todo.")], required: ["path"]) { [weak integration] input in
                guard let connection = integration?.connection else { throw ToolError("Connect Acme in Settings.") }
                return try await connection.get(try apiPath(input["path"]?.string ?? "/"), service: "Acme")
            },
            DashiiTool(name: "acme_tickets", description: "List Acme tickets: id, title, status (todo, doing, done), priority, assignee. Read-only.",
                       properties: ["status": JSONSchema.string("Only this status; omit for all.", enum: statuses)]) { [weak integration] input in
                guard let connection = integration?.connection else { throw ToolError("Connect Acme in Settings.") }
                // The schema's enum is a hint to the model, not a check: check it here.
                var path = "/tickets"
                if let status = input["status"]?.string {
                    guard statuses.contains(status) else { throw ToolError("status is one of \(statuses.joined(separator: ", ")).") }
                    path += "?status=\(status)"
                }
                return try await connection.get(path, service: "Acme")
            },
        ]
    }

    /// A path on the API, never another host or a parent directory: the model writes it, and
    /// the request carries the user's token.
    static func apiPath(_ path: String) throws -> String {
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? ""
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !route.contains("@"), !route.contains("\\"),
              !route.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }),
              !route.lowercased().contains("%2e"), !route.lowercased().contains("%2f") else {
            throw ToolError("Give an API path starting with /, like /tickets.")
        }
        return path
    }
}
