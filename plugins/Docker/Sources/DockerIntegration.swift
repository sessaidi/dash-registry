import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// Docker Engine over its unix socket. Contract: id `docker`, baseURL `http://docker`,
/// a `transport` speaking HTTP/1.1 on the socket, exports `socket` and `version`, prefs under `docker.`.
@MainActor
@Observable
final class DockerIntegration: Integration {
    let id = "docker"
    let name = "Docker"
    let systemImage = "shippingbox"
    let metadata = ExtensionMetadata(
        version: "1.2.0", author: .dash,
        summary: "Lists, inspects and controls local Docker containers through the Engine API socket.",
        category: .cloud, tags: ["docker", "containers", "local"])

    static let baseURL = URL(string: "http://docker")!

    private(set) var version: String?
    private(set) var error: String?
    private(set) var checking = false
    /// Bumped when the socket preference changes so views refresh.
    private(set) var revision = 0
    /// Containers acted on recently (reference → when), so their exits aren't reported as crashes.
    private(set) var recentActions: [String: Date] = [:]
    @ObservationIgnored private(set) var host: (any ExtensionContext)?

    var socketPreference: String {
        get { _ = revision; return preferences.string("socket") ?? "" }
        set {
            preferences.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : newValue, "socket")
            revision += 1
        }
    }

    /// The socket in use: the preference, else the first one found.
    var socketPath: String? {
        _ = revision
        return DockerSocket.resolve(preferred: preferences.string("socket"))
    }

    var isConnected: Bool { version != nil && error == nil }

    var connectionState: ConnectionState {
        if checking { return .checking }
        if let error { return .failed(error) }
        guard let socketPath else { return .notConfigured }
        return version.map { .connected("Docker \($0) via \(socketPath)") } ?? .notConfigured
    }

    var connection: IntegrationConnection? {
        guard let path = socketPath else { return nil }
        return IntegrationConnection(baseURL: Self.baseURL, headers: ["Accept": "application/json"], transport: { request in
            try await UnixHTTP.send(request, socketPath: path)
        })
    }

    var exports: JSONValue {
        ["socket": socketPath.map { .string($0) } ?? .null, "version": version.map { .string($0) } ?? .null]
    }

    func start(host: any ExtensionContext) {
        self.host = host
        Task { await verify() }
    }

    /// GET /version on the current socket.
    func verify() async {
        guard let connection else {
            version = nil
            error = nil
            return
        }
        checking = true
        defer { checking = false }
        do {
            let info = try await connection.get("/version", service: "Docker")
            version = info["Version"]?.string ?? "unknown"
            error = nil
        } catch {
            version = nil
            self.error = error.localizedDescription
        }
    }

    func noteAction(on reference: String) {
        let cutoff = Date().addingTimeInterval(-120)
        recentActions = recentActions.filter { $0.value > cutoff }
        recentActions[reference] = Date()
    }

    /// References acted on in the last two minutes.
    var intentionalReferences: [String] {
        let cutoff = Date().addingTimeInterval(-120)
        return recentActions.filter { $0.value > cutoff }.map(\.key)
    }

    func settingsView() -> AnyView { AnyView(DockerSettingsView(integration: self)) }

    // MARK: - Tools

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
                host?.emit("docker.container.\(action)", from: self, title: "Claude ran \(action) on container \(id)")
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

struct DockerSettingsView: View {
    let integration: DockerIntegration
    @State private var socket = ""
    @State private var detected: [String] = []
    /// Which detected sockets Docker actually answers on (a socket file can outlive its runtime).
    @State private var alive: [String: Bool] = [:]

    var body: some View {
        Form {
            Section {
                ConnectionStatusLabel(integration.connectionState)
                LabeledContent("Socket") {
                    HStack {
                        TextField("Socket", text: $socket, prompt: Text(integration.socketPath ?? "Auto-detect"))
                            .labelsHidden()
                            .onSubmit(save)
                        Button("Save", action: save).disabled(socket == integration.socketPreference)
                    }
                }
                Text("Leave empty to use the first socket found.").font(.caption).foregroundStyle(.secondary)
                AsyncButton("Check Connection") { await integration.verify() }
            }
            Section("Detected sockets") {
                if detected.isEmpty {
                    Text("None found. Start Docker Desktop, Colima, OrbStack or Rancher Desktop.").foregroundStyle(.secondary)
                }
                ForEach(detected, id: \.self) { path in
                    ItemRow(path, monospacedTitle: true, leading: {
                        StatusDot(alive[path] == false ? .danger : alive[path] == true ? .success : .neutral)
                            .help(alive[path] == false ? "Not running: \(DockerSocket.startHint(path))" : alive[path] == true ? "Docker answers here" : "Checking…")
                    }, trailing: {
                        if alive[path] == false {
                            Text(path.contains("colima") ? "stopped · colima start" : "not running").font(.caption).foregroundStyle(.secondary)
                        }
                        if path != integration.socketPath {
                            Button("Use") {
                                socket = path
                                save()
                            }
                        }
                    })
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            socket = integration.socketPreference
            detected = DockerSocket.detected()
            Task {
                for path in detected { alive[path] = await UnixHTTP.answers(path) }
            }
        }
    }

    private func save() {
        integration.socketPreference = socket
        Task { await integration.verify() }
    }
}
