import DashKit
import Foundation

/// Dashii's core container tools: list, inspect, logs, and start/stop/restart (asks first).
extension DockerIntegration {
    func requireConnection() throws -> IntegrationConnection {
        guard let connection else { throw ToolError("No Docker socket found. Start Docker or set the socket in Settings → Docker.") }
        return connection
    }

    nonisolated static func containerPath(_ reference: String, _ suffix: String) throws -> String {
        var name = reference.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("/") { name.removeFirst() }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains), name != ".", name != ".." else {
            throw ToolError("Invalid container id or name: \(reference)")
        }
        return "/containers/\(name)/\(suffix)"
    }

    var tools: [DashiiTool] {
        [
            DashiiTool(
                name: "docker_containers", description: "List local Docker containers (id, name, image, state, status).",
                properties: ["all": JSONSchema.boolean("Include stopped containers (default true).")]
            ) { [weak self] input in
                guard let self else { return [] }
                let all = input["all"]?.bool ?? true
                let list = try await requireConnection().get("/containers/json?all=\(all ? 1 : 0)", service: "Docker")
                return .array(DockerContainer.list(list).map(\.json))
            },
            DashiiTool(
                name: "docker_inspect", description: "Inspect a Docker container: state, health, image, command, ports, mounts, labels (no environment variables).",
                properties: ["id": JSONSchema.string("Container id, id prefix or name.")], required: ["id"]
            ) { [weak self] input in
                guard let self else { return .null }
                guard let id = input["id"]?.string else { throw ToolError("Missing id") }
                let info = try await requireConnection().get(Self.containerPath(id, "json"), service: "Docker")
                return Self.inspectSummary(info)
            },
            DashiiTool(
                name: "docker_logs", description: "Recent logs (stdout and stderr) of a Docker container. Output is cut to the last 50,000 characters.",
                properties: [
                    "id": JSONSchema.string("Container id, id prefix or name."),
                    "tail": JSONSchema.integer("Number of lines from the end (default 200, max 5000)."),
                ], required: ["id"]
            ) { [weak self] input in
                guard let self else { return .null }
                guard let id = input["id"]?.string else { throw ToolError("Missing id") }
                let tail = min(max(input["tail"]?.int ?? 200, 1), 5000)
                let connection = try requireConnection()
                guard let url = connection.url(try Self.containerPath(id, "logs") + "?stdout=1&stderr=1&tail=\(tail)") else { throw ToolError("Bad id") }
                let (data, _) = try await connection.send(URLRequest(url: url), service: "Docker")
                let (text, truncated) = DockerLogs.truncate(DockerLogs.text(data, markStderr: true))
                return ["logs": .string(text), "truncated": .bool(truncated)]
            },
            DashiiTool(
                name: "docker_container_action", description: "Start, stop or restart a Docker container.",
                properties: [
                    "id": JSONSchema.string("Container id, id prefix or name."),
                    "action": JSONSchema.string("What to do.", enum: ["start", "stop", "restart"]),
                ], required: ["id", "action"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return .null }
                guard let id = input["id"]?.string else { throw ToolError("Missing id") }
                guard let action = input["action"]?.string, ["start", "stop", "restart"].contains(action) else {
                    throw ToolError("action must be start, stop or restart")
                }
                let connection = try requireConnection()
                guard let url = connection.url(try Self.containerPath(id, action)) else { throw ToolError("Bad id") }
                noteAction(on: id)
                let (_, response) = try await connection.send(try HTTP.request(url, method: "POST"), service: "Docker")
                host?.emit("docker.container.\(action)", from: self, title: "Dashii ran \(action) on container \(id)")
                return ["ok": true, "id": .string(id), "action": .string(action),
                        "note": response.statusCode == 304 ? "Container was already in that state." : nil]
            },
        ] + granularTools
    }

    /// The parts of GET /containers/{id}/json worth showing; environment variables are left out (secrets).
    nonisolated static func inspectSummary(_ info: JSONValue) -> JSONValue {
        var state = info["State"]?.object ?? [:]
        if var health = state["Health"]?.object {
            health["Log"] = health["Log"]?.array.map { .array(Array($0.suffix(3))) }
            state["Health"] = .object(health)
        }
        let config = info["Config"]
        let mounts: [JSONValue] = (info["Mounts"]?.array ?? []).map {
            ["type": $0["Type"] ?? .null, "source": $0["Source"] ?? .null, "destination": $0["Destination"] ?? .null, "rw": $0["RW"] ?? .null]
        }
        let name = info["Name"]?.string.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        return [
            "id": info["Id"] ?? .null,
            "name": name.map { .string($0) } ?? .null,
            "image": config?["Image"] ?? .null,
            "created": info["Created"] ?? .null,
            "state": .object(state),
            "restartCount": info["RestartCount"] ?? .null,
            "command": config?["Cmd"] ?? .null,
            "entrypoint": config?["Entrypoint"] ?? .null,
            "workingDir": config?["WorkingDir"] ?? .null,
            "labels": config?["Labels"] ?? .null,
            "ports": info["NetworkSettings"]?["Ports"] ?? .null,
            "mounts": .array(mounts),
            "restartPolicy": info["HostConfig"]?["RestartPolicy"] ?? .null,
        ]
    }
}
