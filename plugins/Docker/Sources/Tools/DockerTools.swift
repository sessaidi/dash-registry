import DashKit
import Foundation

/// Single-purpose Docker tools, docker-CLI shaped: Claude asks for exactly what it needs
/// (stats, processes, images, volumes, events…) instead of reading whole inspect dumps.
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

    // MARK: Tools

    private func id(_ input: JSONValue) throws -> String {
        guard let id = input["id"]?.string, !id.isEmpty else { throw ToolError("Missing id") }
        return id
    }

    private func raw(_ path: String, method: String = "GET", body: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        let connection = try requireConnection()
        guard let url = connection.url(path) else { throw ToolError("Bad path \(path)") }
        var request = try HTTP.request(url, method: method, body: body)
        if let timeout { request.timeoutInterval = timeout }
        return try await connection.send(request, service: "Docker").0
    }

    private func json(_ path: String, method: String = "GET", body: JSONValue? = nil, timeout: TimeInterval? = nil) async throws -> JSONValue {
        let data = try await raw(path, method: method, body: body, timeout: timeout)
        return data.isEmpty ? .null : try JSONValue.parse(data)
    }

    var granularTools: [DashiiTool] {
        let idProperty = JSONSchema.string("Container id, id prefix or name.")
        return [
            DashiiTool(name: "docker_info", description: "The Docker engine: version, OS, CPUs, memory, how many containers run, are paused or stopped, how many images. Read-only.") { [weak self] _ in
                guard let self else { return .null }
                let info = try await json("/info")
                return ["server_version": info["ServerVersion"] ?? .null, "os": info["OperatingSystem"] ?? .null, "architecture": info["Architecture"] ?? .null,
                        "cpus": info["NCPU"] ?? .null, "memory": .string(Self.bytes(info["MemTotal"]?.double ?? 0)),
                        "containers": ["running": info["ContainersRunning"] ?? 0, "paused": info["ContainersPaused"] ?? 0, "stopped": info["ContainersStopped"] ?? 0],
                        "images": info["Images"] ?? 0, "storage_driver": info["Driver"] ?? .null, "socket": socketPath.map { .string($0) } ?? .null]
            },
            DashiiTool(
                name: "docker_find_containers",
                description: "Containers matching filters (docker ps --filter): name, image (ancestor), label, status, Compose project. Read-only.",
                properties: ["name": JSONSchema.string("Part of the name."), "image": JSONSchema.string("Image the container was made from."),
                             "label": JSONSchema.string("key or key=value."), "status": JSONSchema.string("created, running, paused, restarting, exited or dead."),
                             "project": JSONSchema.string("Compose project name.")]
            ) { [weak self] input in
                guard let self else { return [] }
                var filters: [String: [String]] = [:]
                if let name = input["name"]?.string { filters["name"] = [name] }
                if let image = input["image"]?.string { filters["ancestor"] = [image] }
                var labels = input["label"]?.string.map { [$0] } ?? []
                if let project = input["project"]?.string { labels.append("com.docker.compose.project=\(project)") }
                filters["label"] = labels
                if let status = input["status"]?.string { filters["status"] = [status] }
                let query = ["all=1"] + (Self.filtersQuery(filters).map { [$0] } ?? [])
                return .array(DockerContainer.list(try await json("/containers/json?" + query.joined(separator: "&"))).map(\.json))
            },
            DashiiTool(name: "docker_compose_projects", description: "Docker Compose projects running here: their services, each service's containers and how many are up. Read-only.") { [weak self] _ in
                guard let self else { return [] }
                let filter = Self.filtersQuery(["label": ["com.docker.compose.project"]]) ?? ""
                return Self.composeProjects(try await json("/containers/json?all=1&\(filter)"))
            },
            DashiiTool(
                name: "docker_stats", description: "CPU, memory, network and disk I/O, and process count of a running container right now (docker stats --no-stream). Without an id: every running container. Read-only.",
                properties: ["id": JSONSchema.string("Container id, id prefix or name. Omit for all running containers.")]
            ) { [weak self] input in
                guard let self else { return .null }
                if let id = input["id"]?.string {
                    return Self.statsSummary(try await json(try Self.containerPath(id, "stats") + "?stream=false"))
                }
                let running = DockerContainer.list(try await json("/containers/json"))
                var rows: [JSONValue] = []
                for container in running.prefix(30) {
                    if let stats = try? await json(try Self.containerPath(container.id, "stats") + "?stream=false") { rows.append(Self.statsSummary(stats)) }
                }
                return .array(rows)
            },
            DashiiTool(name: "docker_top", description: "Processes running inside a container (docker top). Read-only.", properties: ["id": idProperty], required: ["id"]) { [weak self] input in
                guard let self else { return .null }
                let top = try await json(try Self.containerPath(try id(input), "top"))
                let titles = top["Titles"]?.array?.compactMap(\.string) ?? []
                return .array((top["Processes"]?.array ?? []).map { row in
                    .object(Dictionary(zip(titles, row.array ?? []), uniquingKeysWith: { first, _ in first }))
                })
            },
            DashiiTool(
                name: "docker_logs_search",
                description: "A container's logs over a time window, optionally only lines containing some text (docker logs --since --until | grep), with timestamps. Read-only.",
                properties: ["id": idProperty, "since_minutes": JSONSchema.integer("How far back, in minutes (default 60)."),
                             "until_minutes": JSONSchema.integer("Stop this many minutes ago (default now)."),
                             "contains": JSONSchema.string("Keep lines containing this text (case-insensitive)."),
                             "stream": JSONSchema.string("Which output.", enum: ["both", "stdout", "stderr"])],
                required: ["id"]
            ) { [weak self] input in
                guard let self else { return .null }
                let now = Int(Date().timeIntervalSince1970)
                let since = now - max(1, input["since_minutes"]?.int ?? 60) * 60
                let stream = input["stream"]?.string ?? "both"
                var query = ["timestamps=1", "since=\(since)", "stdout=\(stream == "stderr" ? 0 : 1)", "stderr=\(stream == "stdout" ? 0 : 1)"]
                if let until = input["until_minutes"]?.int { query.append("until=\(now - until * 60)") }
                let data = try await raw(try Self.containerPath(try id(input), "logs") + "?" + query.joined(separator: "&"))
                var lines = DockerLogs.text(data, markStderr: stream == "both").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                if let needle = input["contains"]?.string, !needle.isEmpty { lines = lines.filter { $0.localizedCaseInsensitiveContains(needle) } }
                let (text, truncated) = DockerLogs.truncate(lines.joined(separator: "\n"))
                return ["lines": .number(Double(lines.count)), "logs": .string(text), "truncated": .bool(truncated)]
            },
            DashiiTool(name: "docker_health", description: "A container's health check: status, failing streak and the last checks' output. Read-only.", properties: ["id": idProperty], required: ["id"]) { [weak self] input in
                guard let self else { return .null }
                let info = try await json(try Self.containerPath(try id(input), "json"))
                guard let health = info["State"]?["Health"] else { return ["health": "none", "note": "This container has no health check."] }
                return ["status": health["Status"] ?? .null, "failing_streak": health["FailingStreak"] ?? 0,
                        "test": info["Config"]?["Healthcheck"]?["Test"] ?? .null, "checks": health["Log"] ?? []]
            },
            DashiiTool(name: "docker_env_names", description: "Names of a container's environment variables, never their values. Read-only.", properties: ["id": idProperty], required: ["id"]) { [weak self] input in
                guard let self else { return .null }
                let info = try await json(try Self.containerPath(try id(input), "json"))
                return .array((info["Config"]?["Env"]?.array ?? []).compactMap { $0.string?.split(separator: "=", maxSplits: 1).first.map { .string(String($0)) } })
            },
            DashiiTool(name: "docker_ports", description: "Published ports of running containers: host address and port to container port. Read-only.") { [weak self] _ in
                guard let self else { return [] }
                return .array((try await json("/containers/json").array ?? []).flatMap { container -> [JSONValue] in
                    let name = DockerContainer(json: container)?.name ?? ""
                    return (container["Ports"]?.array ?? []).filter { $0["PublicPort"] != nil }.map {
                        ["container": .string(name), "host": .string("\($0["IP"]?.string ?? "0.0.0.0"):\($0["PublicPort"]?.int ?? 0)"),
                         "container_port": .string("\($0["PrivatePort"]?.int ?? 0)/\($0["Type"]?.string ?? "tcp")")]
                    }
                })
            },
            DashiiTool(name: "docker_diff", description: "Files a container added (A), changed (C) or deleted (D) compared to its image (docker diff). Read-only.", properties: ["id": idProperty], required: ["id"]) { [weak self] input in
                guard let self else { return .null }
                let changes = try await json(try Self.containerPath(try id(input), "changes")).array ?? []
                let kinds = ["C", "A", "D"]
                return ["count": .number(Double(changes.count)),
                        "changes": .array(changes.prefix(500).map { .string("\(kinds[min(max($0["Kind"]?.int ?? 0, 0), 2)]) \($0["Path"]?.string ?? "")") })]
            },
            DashiiTool(
                name: "docker_images", description: "Local images (docker images): tags, size, age, and which are dangling. Read-only.",
                properties: ["dangling": JSONSchema.boolean("Only dangling (untagged) images."), "reference": JSONSchema.string("Only images matching, e.g. postgres or redis:7*.")]
            ) { [weak self] input in
                guard let self else { return [] }
                var filters: [String: [String]] = [:]
                if input["dangling"]?.bool == true { filters["dangling"] = ["true"] }
                if let reference = input["reference"]?.string { filters["reference"] = [reference] }
                let path = "/images/json" + (Self.filtersQuery(filters).map { "?" + $0 } ?? "")
                return .array((try await json(path).array ?? []).map(Self.imageSummary))
            },
            DashiiTool(
                name: "docker_image_inspect", description: "One image: entrypoint, command, exposed ports, working dir, labels, environment variable names (no values), architecture, size, layers. Read-only.",
                properties: ["image": JSONSchema.string("Image reference or id, e.g. postgres:16.")], required: ["image"]
            ) { [weak self] input in
                guard let self else { return .null }
                guard let image = input["image"]?.string else { throw ToolError("Missing image") }
                let info = try await json(try Self.objectPath("images", image))
                let config = info["Config"]
                return ["id": info["Id"] ?? .null, "tags": info["RepoTags"] ?? [], "created": info["Created"] ?? .null,
                        "architecture": info["Architecture"] ?? .null, "os": info["Os"] ?? .null, "size": .string(Self.bytes(info["Size"]?.double ?? 0)),
                        "entrypoint": config?["Entrypoint"] ?? .null, "command": config?["Cmd"] ?? .null, "working_dir": config?["WorkingDir"] ?? .null,
                        "user": config?["User"] ?? .null, "exposed_ports": .array((config?["ExposedPorts"]?.object ?? [:]).keys.sorted().map { .string($0) }),
                        "env_names": .array((config?["Env"]?.array ?? []).compactMap { $0.string?.split(separator: "=").first.map { .string(String($0)) } }),
                        "labels": config?["Labels"] ?? .null, "layers": .number(Double(info["RootFS"]?["Layers"]?.array?.count ?? 0))]
            },
            DashiiTool(
                name: "docker_image_history", description: "How an image was built, newest layer first: each step's instruction and size (docker history). Read-only.",
                properties: ["image": JSONSchema.string("Image reference or id.")], required: ["image"]
            ) { [weak self] input in
                guard let self else { return .null }
                guard let image = input["image"]?.string else { throw ToolError("Missing image") }
                return .array((try await json(try Self.objectPath("images", image, "history")).array ?? []).map {
                    ["step": .string(String(($0["CreatedBy"]?.string ?? "").prefix(300))), "size": .string(Self.bytes($0["Size"]?.double ?? 0)),
                     "created": $0["Created"]?.double.map { .string(Date(timeIntervalSince1970: $0).formatted(.iso8601)) } ?? .null]
                })
            },
            DashiiTool(name: "docker_volumes", description: "Volumes (docker volume ls): driver, mountpoint, labels, and whether a container uses them. Read-only.") { [weak self] _ in
                guard let self else { return [] }
                let volumes = try await json("/volumes")["Volumes"]?.array ?? []
                let containers = try await json("/containers/json?all=1").array ?? []
                let used = Set(containers.flatMap { ($0["Mounts"]?.array ?? []).compactMap { $0["Name"]?.string } })
                return .array(volumes.map {
                    let name = $0["Name"]?.string ?? ""
                    return ["name": .string(name), "driver": $0["Driver"] ?? .null, "mountpoint": $0["Mountpoint"] ?? .null,
                            "created": $0["CreatedAt"] ?? .null, "labels": $0["Labels"] ?? .null, "in_use": .bool(used.contains(name))]
                })
            },
            DashiiTool(name: "docker_networks", description: "Networks (docker network ls) with their driver, subnet and the containers attached. Read-only.") { [weak self] _ in
                guard let self else { return [] }
                var rows: [JSONValue] = []
                for network in try await json("/networks").array ?? [] {
                    // The list leaves Containers empty; inspecting each network fills it.
                    let id = network["Id"]?.string ?? ""
                    let detail = (try? await json(try Self.objectPath("networks", id, ""))) ?? network
                    let attached = (detail["Containers"]?.object ?? [:]).values.map {
                        JSONValue.string("\($0["Name"]?.string ?? "?") \($0["IPv4Address"]?.string ?? "")".trimmingCharacters(in: .whitespaces))
                    }
                    rows.append(["name": network["Name"] ?? .null, "driver": network["Driver"] ?? .null, "scope": network["Scope"] ?? .null,
                                 "subnets": .array((network["IPAM"]?["Config"]?.array ?? []).compactMap { $0["Subnet"] }),
                                 "containers": .array(attached.sorted { ($0.string ?? "") < ($1.string ?? "") })])
                }
                return .array(rows)
            },
            DashiiTool(name: "docker_disk_usage", description: "Space used by images, containers, volumes and build cache (docker system df). Read-only.") { [weak self] _ in
                guard let self else { return .null }
                return Self.diskUsage(try await json("/system/df", timeout: 120))
            },
            DashiiTool(
                name: "docker_events",
                description: "What happened recently (docker events): containers created, started, died (with exit code), killed by OOM, health changes, images pulled… Read-only.",
                properties: ["since_minutes": JSONSchema.integer("How far back, in minutes (default 30)."),
                             "container": JSONSchema.string("Only this container's events."),
                             "type": JSONSchema.string("Only one kind of object.", enum: ["container", "image", "volume", "network"])]
            ) { [weak self] input in
                guard let self else { return [] }
                let now = Int(Date().timeIntervalSince1970)
                var filters: [String: [String]] = [:]
                if let container = input["container"]?.string { filters["container"] = [container] }
                if let type = input["type"]?.string { filters["type"] = [type] }
                let since = now - max(1, input["since_minutes"]?.int ?? 30) * 60
                let query = ["since=\(since)", "until=\(now)"] + (Self.filtersQuery(filters).map { [$0] } ?? [])
                let events = Self.eventLines(try await raw("/events?" + query.joined(separator: "&")))
                return .array(Array(events.suffix(200)))
            },

            // MARK: Changes (approval)

            DashiiTool(
                name: "docker_container_state", description: "Pause, unpause or kill (with a signal) a Docker container.",
                properties: ["id": idProperty, "action": JSONSchema.string("What to do.", enum: ["pause", "unpause", "kill"]),
                             "signal": JSONSchema.string("For kill: SIGTERM, SIGINT, SIGHUP… (default SIGKILL).")],
                required: ["id", "action"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return .null }
                let id = try id(input)
                guard let action = input["action"]?.string, ["pause", "unpause", "kill"].contains(action) else { throw ToolError("action must be pause, unpause or kill") }
                var path = try Self.containerPath(id, action)
                if action == "kill", let signal = input["signal"]?.string {
                    guard signal.allSatisfy({ $0.isLetter || $0.isNumber }) else { throw ToolError("Invalid signal \(signal)") }
                    path += "?signal=\(signal)"
                }
                noteAction(on: id)
                _ = try await raw(path, method: "POST")
                host?.emit("docker.container.\(action)", from: self, title: "Dashii ran \(action) on container \(id)")
                return ["ok": true, "id": .string(id), "action": .string(action)]
            },
            DashiiTool(
                name: "docker_remove_container", description: "Remove a stopped container (docker rm). With force, a running one too; with volumes, its anonymous volumes as well.",
                properties: ["id": idProperty, "force": JSONSchema.boolean("Kill and remove a running container."),
                             "volumes": JSONSchema.boolean("Also remove its anonymous volumes.")],
                required: ["id"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return .null }
                let id = try id(input)
                let path = try Self.containerPath(id, "").dropLast() + "?force=\(input["force"]?.bool == true ? 1 : 0)&v=\(input["volumes"]?.bool == true ? 1 : 0)"
                noteAction(on: id)
                _ = try await raw(String(path), method: "DELETE")
                host?.emit("docker.container.removed", from: self, title: "Dashii removed container \(id)")
                return ["ok": true, "removed": .string(id)]
            },
            DashiiTool(
                name: "docker_exec", description: "Run a command inside a running container (docker exec, no TTY) and return its output and exit code. Times out after 60 seconds.",
                properties: ["id": idProperty, "command": ["type": "array", "items": ["type": "string"], "description": "The command and its arguments, e.g. [\"ls\", \"-la\", \"/app\"]."],
                             "workdir": JSONSchema.string("Working directory."), "user": JSONSchema.string("User to run as.")],
                required: ["id", "command"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return .null }
                let id = try id(input)
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
                host?.emit("docker.container.exec", from: self, title: "Dashii ran \(command.joined(separator: " ")) in \(id)")
                return ["exit_code": result["ExitCode"] ?? .null, "output": .string(text), "truncated": .bool(truncated)]
            },
            DashiiTool(
                name: "docker_image_pull", description: "Pull an image from its registry (docker pull). Waits up to 10 minutes.",
                properties: ["image": JSONSchema.string("e.g. postgres:16 or ghcr.io/org/app:1.2. Without a tag, latest.")], required: ["image"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return .null }
                guard let image = input["image"]?.string, !image.isEmpty else { throw ToolError("Missing image") }
                _ = try Self.objectPath("images", image)
                let encoded = image.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? image
                let tagged = image.split(separator: "/").last?.contains(":") == true || image.contains("@")
                let data = try await raw("/images/create?fromImage=\(encoded)" + (tagged ? "" : "&tag=latest"), method: "POST", timeout: 600)
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONValue.parse(Data($0.utf8)) }
                if let failure = lines.first(where: { $0["error"] != nil }) { throw ToolError(failure["error"]?.string ?? "Pull failed") }
                host?.emit("docker.image.pulled", from: self, title: "Dashii pulled \(image)")
                return ["ok": true, "image": .string(image), "status": lines.last?["status"] ?? .null]
            },
            DashiiTool(
                name: "docker_prune", description: "Free space: remove stopped containers, dangling images, unused networks or build cache (docker … prune). Volumes are never pruned.",
                properties: ["what": JSONSchema.string("What to remove.", enum: ["containers", "images", "networks", "build_cache"])],
                required: ["what"], requiresApproval: true
            ) { [weak self] input in
                guard let self else { return .null }
                let paths = ["containers": "/containers/prune", "images": "/images/prune", "networks": "/networks/prune", "build_cache": "/build/prune"]
                guard let what = input["what"]?.string, let path = paths[what] else { throw ToolError("what must be containers, images, networks or build_cache") }
                let result = try await json(path, method: "POST", timeout: 300)
                let removed = (result["ContainersDeleted"] ?? result["ImagesDeleted"] ?? result["NetworksDeleted"] ?? result["CachesDeleted"])?.array?.count ?? 0
                host?.emit("docker.pruned", from: self, title: "Dashii pruned Docker \(what.replacingOccurrences(of: "_", with: " "))")
                return ["removed": .number(Double(removed)), "space_reclaimed": .string(Self.bytes(result["SpaceReclaimed"]?.double ?? 0))]
            },
        ]
    }
}
