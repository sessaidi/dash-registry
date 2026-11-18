import DashKit
import Foundation

/// The engine's answers shaped like the docker CLI's (stats, images, events…), and the changes
/// the user can make: pause, kill, remove, exec, pull, prune.
extension DockerIntegration {
    // MARK: Pure helpers (tested)

    /// The Engine's `filters` query value: `{"label":["a=b"],"status":["running"]}`, URL-encoded.
    nonisolated static func filtersQuery(_ filters: [String: [String]]) -> String? {
        let kept = filters.filter { !$0.value.isEmpty }
        guard !kept.isEmpty else { return nil }
        let json = JSONValue.object(kept.mapValues { .array($0.map { .string($0) }) }).jsonString()
        return "filters=" + (json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? json)
    }

    /// `docker stats --no-stream` for one container, from GET /containers/{id}/stats?stream=false.
    nonisolated static func statsSummary(_ stats: JSONValue) -> JSONValue {
        let cpu = stats["cpu_stats"]
        let previous = stats["precpu_stats"]
        let cpuDelta = (cpu?["cpu_usage"]?["total_usage"]?.double ?? 0) - (previous?["cpu_usage"]?["total_usage"]?.double ?? 0)
        let systemDelta = (cpu?["system_cpu_usage"]?.double ?? 0) - (previous?["system_cpu_usage"]?.double ?? 0)
        let cpus = cpu?["online_cpus"]?.double ?? Double(cpu?["cpu_usage"]?["percpu_usage"]?.array?.count ?? 1)
        let cpuPercent = systemDelta > 0 && cpuDelta > 0 ? cpuDelta / systemDelta * cpus * 100 : 0

        let memory = stats["memory_stats"]
        // Like the CLI: page cache doesn't count as used.
        let cache = memory?["stats"]?["inactive_file"]?.double ?? memory?["stats"]?["cache"]?.double ?? 0
        let used = max(0, (memory?["usage"]?.double ?? 0) - cache)
        let limit = memory?["limit"]?.double ?? 0

        var received = 0.0
        var sent = 0.0
        for network in (stats["networks"]?.object ?? [:]).values {
            received += network["rx_bytes"]?.double ?? 0
            sent += network["tx_bytes"]?.double ?? 0
        }
        var read = 0.0
        var written = 0.0
        for entry in stats["blkio_stats"]?["io_service_bytes_recursive"]?.array ?? [] {
            switch entry["op"]?.string?.lowercased() {
            case "read": read += entry["value"]?.double ?? 0
            case "write": written += entry["value"]?.double ?? 0
            default: break
            }
        }
        let name = stats["name"]?.string.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        return [
            "name": name.map { .string($0) } ?? .null,
            "cpu_percent": .number((cpuPercent * 100).rounded() / 100),
            "memory": .string("\(bytes(used)) / \(bytes(limit))"),
            "memory_percent": .number(limit > 0 ? (used / limit * 10_000).rounded() / 100 : 0),
            "network_rx_tx": .string("\(bytes(received)) / \(bytes(sent))"),
            "block_read_write": .string("\(bytes(read)) / \(bytes(written))"),
            "pids": stats["pids_stats"]?["current"] ?? .null,
        ]
    }

    /// Bytes as the CLI shows them: 512B, 1.5KiB, 20.3MiB, 1.2GiB.
    nonisolated static func bytes(_ value: Double) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var amount = value
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return unit == 0 ? "\(Int(amount))B" : String(format: "%.1f%@", amount, units[unit])
    }

    /// One line of GET /images/json.
    nonisolated static func imageSummary(_ image: JSONValue) -> JSONValue {
        let tags = image["RepoTags"]?.array?.compactMap(\.string).filter { $0 != "<none>:<none>" } ?? []
        return [
            "id": .string(String((image["Id"]?.string ?? "").replacingOccurrences(of: "sha256:", with: "").prefix(12))),
            "tags": .array(tags.map { .string($0) }),
            "dangling": .bool(tags.isEmpty),
            "size": .string(bytes(image["Size"]?.double ?? 0)),
            "created": image["Created"]?.double.map { .string(Date(timeIntervalSince1970: $0).formatted(.iso8601)) } ?? .null,
            "containers": image["Containers"] ?? .null,
        ]
    }

    /// Containers grouped by Compose project and service, from their com.docker.compose labels.
    nonisolated static func composeProjects(_ containers: JSONValue) -> JSONValue {
        var projects: [String: [String: [JSONValue]]] = [:]
        for container in containers.array ?? [] {
            let labels = container["Labels"]
            guard let project = labels?["com.docker.compose.project"]?.string else { continue }
            let service = labels?["com.docker.compose.service"]?.string ?? "?"
            let summary = DockerContainer(json: container)?.json ?? .null
            projects[project, default: [:]][service, default: []].append(summary)
        }
        return .array(projects.keys.sorted().map { project in
            let services = projects[project] ?? [:]
            let running = services.values.joined().filter { $0["state"]?.string == "running" }.count
            let total = services.values.joined().count
            return ["project": .string(project), "running": .string("\(running)/\(total)"),
                    "services": .object(services.mapValues { .array($0) })]
        })
    }

    /// One line per event of GET /events (a JSON object per line).
    nonisolated static func eventLines(_ data: Data) -> [JSONValue] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let event = try? JSONValue.parse(Data(line.utf8)) else { return nil }
            let attributes = event["Actor"]?["Attributes"]
            let time = event["time"]?.double.map { Date(timeIntervalSince1970: $0).formatted(.iso8601) }
            return [
                "time": time.map { .string($0) } ?? .null,
                "type": event["Type"] ?? .null,
                "action": event["Action"] ?? event["status"] ?? .null,
                "name": attributes?["name"] ?? .null,
                "image": attributes?["image"] ?? .null,
                "exit_code": attributes?["exitCode"] ?? .null,
            ]
        }
    }

    /// `docker system df` from GET /system/df.
    nonisolated static func diskUsage(_ df: JSONValue) -> JSONValue {
        func sum(_ items: [JSONValue]?, _ key: String) -> Double { (items ?? []).reduce(0) { $0 + ($1[key]?.double ?? 0) } }
        let images = df["Images"]?.array
        let containers = df["Containers"]?.array
        let volumes = df["Volumes"]?.array
        let cache = df["BuildCache"]?.array
        return [
            "images": ["count": .number(Double(images?.count ?? 0)), "size": .string(bytes(sum(images, "Size"))),
                       "unused": .number(Double(images?.filter { ($0["Containers"]?.int ?? 0) == 0 }.count ?? 0))],
            "containers": ["count": .number(Double(containers?.count ?? 0)), "writable_layers": .string(bytes(sum(containers, "SizeRw")))],
            "volumes": ["count": .number(Double(volumes?.count ?? 0)),
                        "size": .string(bytes((volumes ?? []).reduce(0) { $0 + max(0, $1["UsageData"]?["Size"]?.double ?? 0) }))],
            "build_cache": ["count": .number(Double(cache?.count ?? 0)), "size": .string(bytes(sum(cache, "Size")))],
            "layers_size": .string(bytes(df["LayersSize"]?.double ?? 0)),
        ]
    }

    /// Image references and volume/network names go into paths; keep them to what Docker allows.
    nonisolated static func objectPath(_ prefix: String, _ reference: String, _ suffix: String = "json") throws -> String {
        let name = reference.trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-:/@")
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains), !name.contains(".."), !name.hasPrefix("/") else {
            throw ToolError("Invalid name: \(reference)")
        }
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "_.-"))) ?? name
        return "/\(prefix)/\(encoded)/\(suffix)"
    }

    // MARK: Engine calls

    func raw(_ path: String, method: String = "GET", body: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        let connection = try requireConnection()
        guard let url = connection.url(path) else { throw ToolError("Bad path \(path)") }
        var request = try HTTP.request(url, method: method, body: body)
        if let timeout { request.timeoutInterval = timeout }
        return try await connection.send(request, service: "Docker").0
    }

    func json(_ path: String, method: String = "GET", body: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        let data = try await raw(path, method: method, body: body, timeout: timeout)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    // MARK: Changes (the user's: asked first, never given to Dashii or agents)

    var changeTools: [DashiiTool] {
        let idProperty = Self.idProperty
        return [
            DashiiTool(
                name: "docker_container_state", description: "Pause, unpause or kill (with a signal) a Docker container.",
                properties: ["id": idProperty, "action": JSONSchema.string("What to do.", enum: ["pause", "unpause", "kill"]),
                             "signal": JSONSchema.string("For kill: SIGTERM, SIGINT, SIGHUP… (default SIGKILL).")],
                required: ["id", "action"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return .null }
                let id = try Self.id(input)
                guard let action = input["action"]?.string, ["pause", "unpause", "kill"].contains(action) else { throw ToolError("action must be pause, unpause or kill") }
                var path = try Self.containerPath(id, action)
                if action == "kill", let signal = input["signal"]?.string {
                    guard signal.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw ToolError("Invalid signal \(signal)") }
                    path += "?signal=\(signal)"
                }
                noteAction(on: id)
                _ = try await raw(path, method: "POST")
                host?.emit("docker.container.\(action)", from: self, title: "Ran \(action) on container \(id)")
                return ["ok": true, "id": .string(id), "action": .string(action)]
            },
            DashiiTool(
                name: "docker_remove_container", description: "Remove a stopped container (docker rm). With force, a running one too; with volumes, its anonymous volumes as well.",
                properties: ["id": idProperty, "force": JSONSchema.boolean("Kill and remove a running container."),
                             "volumes": JSONSchema.boolean("Also remove its anonymous volumes.")],
                required: ["id"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return .null }
                let id = try Self.id(input)
                let path = try Self.containerPath(id, "").dropLast() + "?force=\(input["force"]?.bool == true ? 1 : 0)&v=\(input["volumes"]?.bool == true ? 1 : 0)"
                noteAction(on: id)
                _ = try await raw(String(path), method: "DELETE")
                host?.emit("docker.container.removed", from: self, title: "Removed container \(id)")
                return ["ok": true, "removed": .string(id)]
            },
            DashiiTool(
                name: "docker_exec", description: "Run a command inside a running container (docker exec, no TTY) and return its output and exit code. Times out after 60 seconds.",
                properties: ["id": idProperty, "command": ["type": "array", "items": ["type": "string"], "description": "The command and its arguments, e.g. [\"ls\", \"-la\", \"/app\"]."],
                             "workdir": JSONSchema.string("Working directory."), "user": JSONSchema.string("User to run as.")],
                required: ["id", "command"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return .null }
                let id = try Self.id(input)
                let command = input["command"]?.array?.compactMap(\.string) ?? []
                guard !command.isEmpty else { throw ToolError("Missing command") }
                var body: [String: JSONValue] = ["Cmd": .array(command.map { .string($0) }), "AttachStdout": true, "AttachStderr": true, "Tty": false]
                if let workdir = input["workdir"]?.string { body["WorkingDir"] = .string(workdir) }
                if let user = input["user"]?.string { body["User"] = .string(user) }
                let created = try await json(try Self.containerPath(id, "exec"), method: "POST", body: .object(body))
                guard let execID = created["Id"]?.string else { throw ToolError("Docker did not create the exec.") }
                let output = try await raw(try Self.objectPath("exec", execID, "start"), method: "POST", body: ["Detach": false, "Tty": false], timeout: 60)
                let result = try await json(try Self.objectPath("exec", execID))
                let (text, truncated) = DockerLogs.truncate(DockerLogs.text(output, markStderr: true))
                host?.emit("docker.container.exec", from: self, title: "Ran \(command.joined(separator: " ")) in \(id)")
                return ["exit_code": result["ExitCode"] ?? .null, "output": .string(text), "truncated": .bool(truncated)]
            },
            DashiiTool(
                name: "docker_image_pull", description: "Pull an image from its registry (docker pull). Waits up to 10 minutes.",
                properties: ["image": JSONSchema.string("e.g. postgres:16 or ghcr.io/org/app:1.2. Without a tag, latest.")], required: ["image"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return .null }
                guard let image = input["image"]?.string, !image.isEmpty else { throw ToolError("Missing image") }
                _ = try Self.objectPath("images", image)
                let encoded = image.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? image
                let tagged = image.split(separator: "/").last?.contains(":") == true || image.contains("@")
                let data = try await raw("/images/create?fromImage=\(encoded)" + (tagged ? "" : "&tag=latest"), method: "POST", timeout: 600)
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
                if let failure = lines.first(where: { $0["error"] != nil }) { throw ToolError(failure["error"]?.string ?? "Pull failed") }
                host?.emit("docker.image.pulled", from: self, title: "Pulled \(image)")
                return ["ok": true, "image": .string(image), "status": lines.last?["status"] ?? .null]
            },
            DashiiTool(
                name: "docker_prune", description: "Free space: remove stopped containers, dangling images, unused networks or build cache (docker … prune). Volumes are never pruned.",
                properties: ["what": JSONSchema.string("What to remove.", enum: ["containers", "images", "networks", "build_cache"])],
                required: ["what"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return .null }
                let paths = ["containers": "/containers/prune", "images": "/images/prune", "networks": "/networks/prune", "build_cache": "/build/prune"]
                guard let what = input["what"]?.string, let path = paths[what] else { throw ToolError("what must be containers, images, networks or build_cache") }
                let result = try await json(path, method: "POST", timeout: 300)
                let removed = (result["ContainersDeleted"] ?? result["ImagesDeleted"] ?? result["NetworksDeleted"] ?? result["CachesDeleted"])?.array?.count ?? 0
                host?.emit("docker.pruned", from: self, title: "Pruned Docker \(what.replacingOccurrences(of: "_", with: " "))")
                return ["removed": .number(Double(removed)), "space_reclaimed": .string(Self.bytes(result["SpaceReclaimed"]?.double ?? 0))]
            },
        ]
    }
}
