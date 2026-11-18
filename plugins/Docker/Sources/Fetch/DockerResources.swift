import DashKit
import Foundation

/// Something Dash can fetch from the Docker engine and read back: the fetcher `docker.<what>`
/// asks the engine and stores the answer; the reader `docker_<what>` (same input) returns it with
/// its freshness, or says to fetch first.
struct DockerResource {
    let what: String
    /// What it is, for Dashii (the fetcher's summary and the reader's description).
    let summary: String
    var properties: [String: JSONValue] = [:]
    var required: [String] = []
    /// Answers about one container, image or time window: kept a day, then dropped.
    var queryShaped = false
    var freshFor: Duration = .seconds(60)
    /// Asks the engine and returns the answer that gets stored.
    let load: @MainActor (DockerIntegration, JSONValue) async throws -> JSONValue

    var fetcherName: String { "docker." + what }
    var readerName: String { "docker_" + what }
    var kind: String { "docker." + what }
}

extension DockerIntegration {
    static let idProperty = JSONSchema.string("Container id, id prefix or name.")

    /// What Dash fetches from the engine: `docker ps`, `inspect`, `logs`, `stats`, `images`, `events`…
    var resources: [DockerResource] {
        [
            DockerResource(what: "containers", summary: "Local Docker containers (id, name, image, state, status).",
                           properties: ["all": JSONSchema.boolean("Include stopped containers (default true).")]) { docker, input in
                let all = input["all"]?.bool ?? true
                return .array(DockerContainer.list(try await docker.json("/containers/json?all=\(all ? 1 : 0)")).map(\.json))
            },
            DockerResource(what: "inspect", summary: "A Docker container: state, health, image, command, ports, mounts, labels (no environment variables).",
                           properties: ["id": Self.idProperty], required: ["id"], queryShaped: true) { docker, input in
                Self.inspectSummary(try await docker.json(try Self.containerPath(try Self.id(input), "json")))
            },
            DockerResource(what: "logs", summary: "Recent logs (stdout and stderr) of a Docker container, cut to the last 50,000 characters.",
                           properties: ["id": Self.idProperty, "tail": JSONSchema.integer("Number of lines from the end (default 200, max 5000).")],
                           required: ["id"], queryShaped: true) { docker, input in
                let tail = min(max(input["tail"]?.int ?? 200, 1), 5000)
                let data = try await docker.raw(try Self.containerPath(try Self.id(input), "logs") + "?stdout=1&stderr=1&tail=\(tail)")
                let (text, truncated) = DockerLogs.truncate(DockerLogs.text(data, markStderr: true))
                return ["logs": .string(text), "truncated": .bool(truncated)]
            },
            DockerResource(what: "info", summary: "The Docker engine: version, OS, CPUs, memory, how many containers run, are paused or stopped, how many images.",
                           freshFor: .seconds(5 * 60)) { docker, _ in
                let info = try await docker.json("/info")
                return ["server_version": info["ServerVersion"] ?? .null, "os": info["OperatingSystem"] ?? .null, "architecture": info["Architecture"] ?? .null,
                        "cpus": info["NCPU"] ?? .null, "memory": .string(Self.bytes(info["MemTotal"]?.double ?? 0)),
                        "containers": ["running": info["ContainersRunning"] ?? 0, "paused": info["ContainersPaused"] ?? 0, "stopped": info["ContainersStopped"] ?? 0],
                        "images": info["Images"] ?? 0, "storage_driver": info["Driver"] ?? .null, "socket": docker.socketPath.map { .string($0) } ?? .null]
            },
            DockerResource(what: "find_containers", summary: "Containers matching filters (docker ps --filter): name, image (ancestor), label, status, Compose project.",
                           properties: ["name": JSONSchema.string("Part of the name."), "image": JSONSchema.string("Image the container was made from."),
                                        "label": JSONSchema.string("key or key=value."), "status": JSONSchema.string("created, running, paused, restarting, exited or dead."),
                                        "project": JSONSchema.string("Compose project name.")],
                           queryShaped: true) { docker, input in
                var filters: [String: [String]] = [:]
                if let name = input["name"]?.string { filters["name"] = [name] }
                if let image = input["image"]?.string { filters["ancestor"] = [image] }
                var labels = input["label"]?.string.map { [$0] } ?? []
                if let project = input["project"]?.string { labels.append("com.docker.compose.project=\(project)") }
                filters["label"] = labels
                if let status = input["status"]?.string { filters["status"] = [status] }
                let query = ["all=1"] + (Self.filtersQuery(filters).map { [$0] } ?? [])
                return .array(DockerContainer.list(try await docker.json("/containers/json?" + query.joined(separator: "&"))).map(\.json))
            },
            DockerResource(what: "compose_projects", summary: "Docker Compose projects running here: their services, each service's containers and how many are up.") { docker, _ in
                let filter = Self.filtersQuery(["label": ["com.docker.compose.project"]]) ?? ""
                return Self.composeProjects(try await docker.json("/containers/json?all=1&\(filter)"))
            },
            DockerResource(what: "stats", summary: "CPU, memory, network and disk I/O, and process count of a running container (docker stats --no-stream). Without an id: every running container.",
                           properties: ["id": JSONSchema.string("Container id, id prefix or name. Omit for all running containers.")],
                           queryShaped: true) { docker, input in
                if let id = input["id"]?.string {
                    return Self.statsSummary(try await docker.json(try Self.containerPath(id, "stats") + "?stream=false"))
                }
                var rows: [JSONValue] = []
                for container in DockerContainer.list(try await docker.json("/containers/json")).prefix(30) {
                    if let stats = try? await docker.json(try Self.containerPath(container.id, "stats") + "?stream=false") { rows.append(Self.statsSummary(stats)) }
                }
                return .array(rows)
            },
            DockerResource(what: "top", summary: "Processes running inside a container (docker top).",
                           properties: ["id": Self.idProperty], required: ["id"], queryShaped: true) { docker, input in
                let top = try await docker.json(try Self.containerPath(try Self.id(input), "top"))
                let titles = top["Titles"]?.array?.compactMap(\.string) ?? []
                return .array((top["Processes"]?.array ?? []).map { row in
                    .object(Dictionary(zip(titles, row.array ?? []), uniquingKeysWith: { first, _ in first }))
                })
            },
            DockerResource(what: "logs_search", summary: "A container's logs over a time window, optionally only lines containing some text (docker logs --since --until | grep), with timestamps.",
                           properties: ["id": Self.idProperty, "since_minutes": JSONSchema.integer("How far back, in minutes (default 60)."),
                                        "until_minutes": JSONSchema.integer("Stop this many minutes ago (default now)."),
                                        "contains": JSONSchema.string("Keep lines containing this text (case-insensitive)."),
                                        "stream": JSONSchema.string("Which output.", enum: ["both", "stdout", "stderr"])],
                           required: ["id"], queryShaped: true) { docker, input in
                let now = Int(docker.now().timeIntervalSince1970)
                let since = now - max(1, input["since_minutes"]?.int ?? 60) * 60
                let stream = input["stream"]?.string ?? "both"
                var query = ["timestamps=1", "since=\(since)", "stdout=\(stream == "stderr" ? 0 : 1)", "stderr=\(stream == "stdout" ? 0 : 1)"]
                if let until = input["until_minutes"]?.int { query.append("until=\(now - until * 60)") }
                let data = try await docker.raw(try Self.containerPath(try Self.id(input), "logs") + "?" + query.joined(separator: "&"))
                var lines = DockerLogs.text(data, markStderr: stream == "both").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                if let needle = input["contains"]?.string, !needle.isEmpty { lines = lines.filter { $0.localizedCaseInsensitiveContains(needle) } }
                let (text, truncated) = DockerLogs.truncate(lines.joined(separator: "\n"))
                return ["lines": .number(Double(lines.count)), "logs": .string(text), "truncated": .bool(truncated)]
            },
            DockerResource(what: "health", summary: "A container's health check: status, failing streak and the last checks' output.",
                           properties: ["id": Self.idProperty], required: ["id"], queryShaped: true) { docker, input in
                let info = try await docker.json(try Self.containerPath(try Self.id(input), "json"))
                guard let health = info["State"]?["Health"] else { return ["health": "none", "note": "This container has no health check."] }
                return ["status": health["Status"] ?? .null, "failing_streak": health["FailingStreak"] ?? 0,
                        "test": info["Config"]?["Healthcheck"]?["Test"] ?? .null, "checks": health["Log"] ?? []]
            },
            DockerResource(what: "env_names", summary: "Names of a container's environment variables, never their values.",
                           properties: ["id": Self.idProperty], required: ["id"], queryShaped: true) { docker, input in
                let info = try await docker.json(try Self.containerPath(try Self.id(input), "json"))
                return .array((info["Config"]?["Env"]?.array ?? []).compactMap { $0.string?.split(separator: "=", maxSplits: 1).first.map { .string(String($0)) } })
            },
            DockerResource(what: "ports", summary: "Published ports of running containers: host address and port to container port.") { docker, _ in
                .array((try await docker.json("/containers/json").array ?? []).flatMap { container -> [JSONValue] in
                    let name = DockerContainer(json: container)?.name ?? ""
                    return (container["Ports"]?.array ?? []).filter { $0["PublicPort"] != nil }.map {
                        ["container": .string(name), "host": .string("\($0["IP"]?.string ?? "0.0.0.0"):\($0["PublicPort"]?.int ?? 0)"),
                         "container_port": .string("\($0["PrivatePort"]?.int ?? 0)/\($0["Type"]?.string ?? "tcp")")]
                    }
                })
            },
            DockerResource(what: "diff", summary: "Files a container added (A), changed (C) or deleted (D) compared to its image (docker diff).",
                           properties: ["id": Self.idProperty], required: ["id"], queryShaped: true) { docker, input in
                let changes = try await docker.json(try Self.containerPath(try Self.id(input), "changes")).array ?? []
                let kinds = ["C", "A", "D"]
                return ["count": .number(Double(changes.count)),
                        "changes": .array(changes.prefix(500).map { .string("\(kinds[min(max($0["Kind"]?.int ?? 0, 0), 2)]) \($0["Path"]?.string ?? "")") })]
            },
            DockerResource(what: "images", summary: "Local images (docker images): tags, size, age, and which are dangling.",
                           properties: ["dangling": JSONSchema.boolean("Only dangling (untagged) images."), "reference": JSONSchema.string("Only images matching, e.g. postgres or redis:7*.")],
                           freshFor: .seconds(5 * 60)) { docker, input in
                var filters: [String: [String]] = [:]
                if input["dangling"]?.bool == true { filters["dangling"] = ["true"] }
                if let reference = input["reference"]?.string { filters["reference"] = [reference] }
                let path = "/images/json" + (Self.filtersQuery(filters).map { "?" + $0 } ?? "")
                return .array((try await docker.json(path).array ?? []).map(Self.imageSummary))
            },
            DockerResource(what: "image_inspect", summary: "One image: entrypoint, command, exposed ports, working dir, labels, environment variable names (no values), architecture, size, layers.",
                           properties: ["image": JSONSchema.string("Image reference or id, e.g. postgres:16.")], required: ["image"],
                           queryShaped: true, freshFor: .seconds(3600)) { docker, input in
                let info = try await docker.json(try Self.objectPath("images", input["image"]?.string ?? ""))
                let config = info["Config"]
                return ["id": info["Id"] ?? .null, "tags": info["RepoTags"] ?? [], "created": info["Created"] ?? .null,
                        "architecture": info["Architecture"] ?? .null, "os": info["Os"] ?? .null, "size": .string(Self.bytes(info["Size"]?.double ?? 0)),
                        "entrypoint": config?["Entrypoint"] ?? .null, "command": config?["Cmd"] ?? .null, "working_dir": config?["WorkingDir"] ?? .null,
                        "user": config?["User"] ?? .null, "exposed_ports": .array((config?["ExposedPorts"]?.object ?? [:]).keys.sorted().map { .string($0) }),
                        "env_names": .array((config?["Env"]?.array ?? []).compactMap { $0.string?.split(separator: "=").first.map { .string(String($0)) } }),
                        "labels": config?["Labels"] ?? .null, "layers": .number(Double(info["RootFS"]?["Layers"]?.array?.count ?? 0))]
            },
            DockerResource(what: "image_history", summary: "How an image was built, newest layer first: each step's instruction and size (docker history).",
                           properties: ["image": JSONSchema.string("Image reference or id.")], required: ["image"],
                           queryShaped: true, freshFor: .seconds(3600)) { docker, input in
                .array((try await docker.json(try Self.objectPath("images", input["image"]?.string ?? "", "history")).array ?? []).map {
                    ["step": .string(String(($0["CreatedBy"]?.string ?? "").prefix(300))), "size": .string(Self.bytes($0["Size"]?.double ?? 0)),
                     "created": $0["Created"]?.double.map { .string(Date(timeIntervalSince1970: $0).formatted(.iso8601)) } ?? .null]
                })
            },
            DockerResource(what: "volumes", summary: "Volumes (docker volume ls): driver, mountpoint, labels, and whether a container uses them.",
                           freshFor: .seconds(5 * 60)) { docker, _ in
                let volumes = try await docker.json("/volumes")["Volumes"]?.array ?? []
                let containers = try await docker.json("/containers/json?all=1").array ?? []
                let used = Set(containers.flatMap { ($0["Mounts"]?.array ?? []).compactMap { $0["Name"]?.string } })
                return .array(volumes.map {
                    let name = $0["Name"]?.string ?? ""
                    return ["name": .string(name), "driver": $0["Driver"] ?? .null, "mountpoint": $0["Mountpoint"] ?? .null,
                            "created": $0["CreatedAt"] ?? .null, "labels": $0["Labels"] ?? .null, "in_use": .bool(used.contains(name))]
                })
            },
            DockerResource(what: "networks", summary: "Networks (docker network ls) with their driver, subnet and the containers attached.",
                           freshFor: .seconds(5 * 60)) { docker, _ in
                var rows: [JSONValue] = []
                for network in try await docker.json("/networks").array ?? [] {
                    // The list leaves Containers empty; inspecting each network fills it.
                    let id = network["Id"]?.string ?? ""
                    let detail = (try? await docker.json(try Self.objectPath("networks", id, ""))) ?? network
                    let attached = (detail["Containers"]?.object ?? [:]).values.map {
                        JSONValue.string("\($0["Name"]?.string ?? "?") \($0["IPv4Address"]?.string ?? "")".trimmingCharacters(in: .whitespaces))
                    }
                    rows.append(["name": network["Name"] ?? .null, "driver": network["Driver"] ?? .null, "scope": network["Scope"] ?? .null,
                                 "subnets": .array((network["IPAM"]?["Config"]?.array ?? []).compactMap { $0["Subnet"] }),
                                 "containers": .array(attached.sorted { ($0.string ?? "") < ($1.string ?? "") })])
                }
                return .array(rows)
            },
            DockerResource(what: "disk_usage", summary: "Space used by images, containers, volumes and build cache (docker system df).",
                           freshFor: .seconds(15 * 60)) { docker, _ in
                Self.diskUsage(try await docker.json("/system/df", timeout: 120))
            },
            DockerResource(what: "events", summary: "What happened recently (docker events): containers created, started, died (with exit code), killed by OOM, health changes, images pulled…",
                           properties: ["since_minutes": JSONSchema.integer("How far back, in minutes (default 30)."),
                                        "container": JSONSchema.string("Only this container's events."),
                                        "type": JSONSchema.string("Only one kind of object.", enum: ["container", "image", "volume", "network"])],
                           queryShaped: true) { docker, input in
                let now = Int(docker.now().timeIntervalSince1970)
                var filters: [String: [String]] = [:]
                if let container = input["container"]?.string { filters["container"] = [container] }
                if let type = input["type"]?.string { filters["type"] = [type] }
                let since = now - max(1, input["since_minutes"]?.int ?? 30) * 60
                let query = ["since=\(since)", "until=\(now)"] + (Self.filtersQuery(filters).map { [$0] } ?? [])
                return .array(Array(Self.eventLines(try await docker.raw("/events?" + query.joined(separator: "&"))).suffix(200)))
            },
        ]
    }

    nonisolated static func id(_ input: JSONValue) throws -> String {
        guard let id = input["id"]?.string, !id.isEmpty else { throw ToolError("Missing id") }
        return id
    }
}
