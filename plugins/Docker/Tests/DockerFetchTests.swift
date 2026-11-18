import DashKit
import DashKitTesting
import Foundation
import Testing

/// An engine that answers from a table by path (query left out) and records what it was asked.
final class StubEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []
    let routes: [String: String]

    init(_ routes: [String: String]) { self.routes = routes }

    var requests: [URLRequest] { lock.withLock { log } }
    var paths: [String] { requests.map { $0.url?.path(percentEncoded: false) ?? "" } }

    var transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        { [self] request in
            lock.withLock { log.append(request) }
            let path = request.url?.path(percentEncoded: false) ?? ""
            let body = routes[path] ?? (path.hasSuffix("/stats") ? routes["stats"] : nil)
            let response = HTTPURLResponse(url: request.url!, statusCode: body == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data((body ?? #"{"message":"no such object"}"#).utf8), response)
        }
    }
}

/// Fetch, then read: each fetcher asks the engine and stores a sanitized answer with a receipt;
/// each reader answers from the store with its freshness, or says what to fetch. No tool Dashii or
/// an agent gets talks to the engine, and the changes are the user's.
@MainActor
@Suite("Docker fetch")
struct DockerFetchTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let fetcher: String
        var input: JSONValue = [:]
        /// A path the fetch must ask the engine for.
        let request: String
        let check: @Sendable (JSONValue) -> Bool
        var testDescription: String { fetcher }
    }

    nonisolated static let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"

    nonisolated static let routes: [String: String] = [
        "/version": #"{"Version":"27.3.1"}"#,
        "/containers/json": #"[{"Id":"abc123def4567890","Names":["/web"],"Image":"nginx:1.27","State":"running","Status":"Up 3 hours (healthy)","#
            + #""Labels":{"com.docker.compose.project":"shop","com.docker.compose.service":"web"},"#
            + #""Ports":[{"IP":"0.0.0.0","PrivatePort":80,"PublicPort":8080,"Type":"tcp"},{"PrivatePort":443,"Type":"tcp"}],"Mounts":[{"Name":"data"}]}]"#,
        "/containers/web/json": #"{"Id":"abc123def4567890","Name":"/web","Created":"2026-11-18T09:00:00Z","#
            + #""State":{"Status":"running","Health":{"Status":"healthy","FailingStreak":0,"Log":[{"ExitCode":0,"Output":"ok"}]}},"#
            + #""Config":{"Image":"nginx:1.27","Env":["GITHUB_TOKEN=\#(token)","PATH=/usr/bin"],"Healthcheck":{"Test":["CMD","true"]}},"#
            + #""Mounts":[],"NetworkSettings":{"Ports":{}},"HostConfig":{"RestartPolicy":{"Name":"always"}}}"#,
        "/containers/web/logs": "2026-11-18T10:00:00Z booting\n2026-11-18T10:00:01Z ERROR push failed with GITHUB_TOKEN=\(token)\n",
        "stats": #"{"name":"/web","cpu_stats":{"cpu_usage":{"total_usage":400},"system_cpu_usage":2000,"online_cpus":4},"#
            + #""precpu_stats":{"cpu_usage":{"total_usage":200},"system_cpu_usage":1000},"memory_stats":{"usage":1048576,"limit":2097152},"pids_stats":{"current":3}}"#,
        "/containers/web/top": #"{"Titles":["PID","CMD"],"Processes":[["1","nginx: master process"]]}"#,
        "/containers/web/changes": #"[{"Kind":1,"Path":"/tmp/cache"}]"#,
        "/info": #"{"ServerVersion":"27.3.1","OperatingSystem":"Docker Desktop","Architecture":"aarch64","NCPU":8,"MemTotal":8589934592,"#
            + #""ContainersRunning":1,"ContainersPaused":0,"ContainersStopped":2,"Images":5,"Driver":"overlay2"}"#,
        "/images/json": #"[{"Id":"sha256:0123456789abcdef","RepoTags":["postgres:16"],"Size":2048,"Created":0,"Containers":1}]"#,
        "/images/postgres:16/json": #"{"Id":"sha256:0123","RepoTags":["postgres:16"],"Architecture":"arm64","Os":"linux","Size":2048,"#
            + #""Config":{"Cmd":["postgres"],"Env":["PGDATA=/var/lib/postgresql/data"],"ExposedPorts":{"5432/tcp":{}}},"RootFS":{"Layers":["a","b"]}}"#,
        "/images/postgres:16/history": #"[{"CreatedBy":"CMD [\"postgres\"]","Size":0,"Created":0}]"#,
        "/volumes": #"{"Volumes":[{"Name":"data","Driver":"local","Mountpoint":"/var/lib/docker/volumes/data"},{"Name":"old","Driver":"local"}]}"#,
        "/networks": #"[{"Id":"n1","Name":"bridge","Driver":"bridge","Scope":"local","IPAM":{"Config":[{"Subnet":"172.17.0.0/16"}]}}]"#,
        "/networks/n1": #"{"Containers":{"abc":{"Name":"web","IPv4Address":"172.17.0.2/16"}}}"#,
        "/system/df": #"{"Images":[{"Size":2048,"Containers":0}],"Containers":[],"Volumes":[],"BuildCache":[],"LayersSize":4096}"#,
        "/events": #"{"Type":"container","Action":"start","time":1763460000,"Actor":{"Attributes":{"name":"web","image":"nginx:1.27"}}}"# + "\n"
            + #"{"Type":"container","Action":"die","time":1763460060,"Actor":{"Attributes":{"name":"worker","image":"billing-api","exitCode":"137"}}}"#,
    ]

    nonisolated static let cases: [Case] = [
        Case(fetcher: "docker.containers", request: "/containers/json") { $0["items"]?[0]?["name"] == "web" && $0["items"]?[0]?["state"] == "running" },
        Case(fetcher: "docker.inspect", input: ["id": "web"], request: "/containers/web/json") {
            $0["name"] == "web" && $0["restartPolicy"]?["Name"] == "always" && !$0.jsonString().contains("GITHUB_TOKEN")
        },
        Case(fetcher: "docker.logs", input: ["id": "web", "tail": 50], request: "/containers/web/logs") {
            $0["logs"]?.string?.contains("booting") == true && $0["logs"]?.string?.contains("ghp_") == false
        },
        Case(fetcher: "docker.info", request: "/info") { $0["server_version"] == "27.3.1" && $0["containers"]?["stopped"] == 2 && $0["memory"] == "8.0GiB" },
        Case(fetcher: "docker.find_containers", input: ["project": "shop"], request: "/containers/json") { $0["items"]?[0]?["name"] == "web" },
        Case(fetcher: "docker.compose_projects", request: "/containers/json") { $0["items"]?[0]?["project"] == "shop" && $0["items"]?[0]?["running"] == "1/1" },
        Case(fetcher: "docker.stats", input: ["id": "web"], request: "/containers/web/stats") { $0["cpu_percent"] == 80 && $0["pids"] == 3 },
        Case(fetcher: "docker.top", input: ["id": "web"], request: "/containers/web/top") { $0["items"]?[0]?["CMD"] == "nginx: master process" },
        Case(fetcher: "docker.logs_search", input: ["id": "web", "contains": "error"], request: "/containers/web/logs") {
            $0["lines"] == 1 && $0["logs"]?.string?.contains("push failed") == true && $0["logs"]?.string?.contains("ghp_") == false
        },
        Case(fetcher: "docker.health", input: ["id": "web"], request: "/containers/web/json") { $0["status"] == "healthy" && $0["failing_streak"] == 0 },
        Case(fetcher: "docker.env_names", input: ["id": "web"], request: "/containers/web/json") {
            $0["items"] == ["GITHUB_TOKEN", "PATH"] && !$0.jsonString().contains("ghp_")
        },
        Case(fetcher: "docker.ports", request: "/containers/json") { $0["items"]?.array?.count == 1 && $0["items"]?[0]?["host"] == "0.0.0.0:8080" },
        Case(fetcher: "docker.diff", input: ["id": "web"], request: "/containers/web/changes") { $0["count"] == 1 && $0["changes"] == ["A /tmp/cache"] },
        Case(fetcher: "docker.images", request: "/images/json") { $0["items"]?[0]?["tags"] == ["postgres:16"] && $0["items"]?[0]?["dangling"] == false },
        Case(fetcher: "docker.image_inspect", input: ["image": "postgres:16"], request: "/images/postgres:16/json") {
            $0["architecture"] == "arm64" && $0["exposed_ports"] == ["5432/tcp"] && $0["env_names"] == ["PGDATA"] && $0["layers"] == 2
        },
        Case(fetcher: "docker.image_history", input: ["image": "postgres:16"], request: "/images/postgres:16/history") {
            $0["items"]?[0]?["step"]?.string?.contains("postgres") == true
        },
        Case(fetcher: "docker.volumes", request: "/volumes") { $0["items"]?[0]?["in_use"] == true && $0["items"]?[1]?["in_use"] == false },
        Case(fetcher: "docker.networks", request: "/networks/n1") { $0["items"]?[0]?["containers"] == ["web 172.17.0.2/16"] },
        Case(fetcher: "docker.disk_usage", request: "/system/df") { $0["images"]?["count"] == 1 && $0["layers_size"] == "4.0KiB" },
        Case(fetcher: "docker.events", input: ["since_minutes": 60], request: "/events") {
            $0["items"]?.array?.count == 2 && $0["items"]?[1]?["exit_code"] == "137"
        },
    ]

    /// A started integration on a stub engine, its version check done.
    func hosted() async throws -> (DockerIntegration, TestHost, StubEngine) {
        let engine = StubEngine(Self.routes)
        let docker = DockerIntegration()
        docker.transport = engine.transport
        let dash = try TestHost([docker])
        dash.start([docker])
        await docker.verify()
        return (docker, dash, engine)
    }

    /// What went to the engine besides the version check.
    func asked(_ engine: StubEngine) -> [String] { engine.paths.filter { $0 != "/version" } }

    @Test(arguments: cases)
    func fetcherStoresAndReaderReads(_ c: Case) async throws {
        let (docker, dash, engine) = try await hosted()
        let resource = try #require(docker.resources.first { $0.fetcherName == c.fetcher })

        let before = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(before["fetched"] == false && before["refresh"]?["fetcher"] == .string(c.fetcher))
        #expect(asked(engine).isEmpty)

        let receipt = try await dash.fetch(c.fetcher, c.input)
        #expect(receipt["stored"] == 1 && receipt["unchanged"] == 0)
        #expect(receipt["keys"]?[0]?.string?.hasPrefix(resource.kind + "/") == true)
        #expect(receipt["read_with"]?.string?.hasPrefix(resource.readerName + " {") == true)
        #expect(asked(engine).contains(c.request), "\(asked(engine))")
        #expect(engine.requests.allSatisfy { $0.httpMethod == "GET" })

        let answer = try #require(try await dash.runTool(resource.readerName, c.input))
        #expect(c.check(answer), "\(answer.jsonString())")
        #expect(answer["stale"] == false && answer["synced_at"]?.string != nil)

        let again = try await dash.fetch(c.fetcher, c.input)
        #expect(again["stored"] == 0 && again["unchanged"] == 1)
        let stored = dash.testSynced.records(kind: resource.kind, scope: docker.storeScope)
        #expect(stored.count == 1 && stored.allSatisfy { $0.source == "docker" && !$0.value.jsonString().contains("ghp_") })
    }

    @Test func logsSearchAsksForTheWindow() async throws {
        let (docker, dash, engine) = try await hosted()
        let now = Date(timeIntervalSince1970: 1_763_463_600)
        docker.now = { now }
        _ = try await dash.fetch("docker.logs_search", ["id": "web", "since_minutes": 30, "until_minutes": 5, "stream": "stderr"])
        let query = try #require(engine.requests.last?.url?.query())
        #expect(query.contains("since=\(1_763_463_600 - 1800)") && query.contains("until=\(1_763_463_600 - 300)"))
        #expect(query.contains("stdout=0") && query.contains("stderr=1"))
    }

    @Test func namesAreCheckedBeforeAnything() async throws {
        let (_, dash, engine) = try await hosted()
        for (name, input) in [("docker_inspect", ["id": "../etc"]), ("docker_image_inspect", ["image": "/etc/passwd"]), ("docker_events", ["container": "a b"])] as [(String, JSONValue)] {
            await #expect(throws: ToolError.self) { try await dash.runTool(name, input) }
        }
        await #expect(throws: ToolError.self) { try await dash.fetch("docker.inspect", ["id": "../etc"]) }
        await #expect(throws: ToolError("Give id.")) { try await dash.runTool("docker_logs", ["id": " "]) }
        #expect(asked(engine).isEmpty)
    }

    @Test func readersSayWhenDataIsStale() async throws {
        let (docker, dash, _) = try await hosted()
        _ = try await dash.fetch("docker.containers")
        _ = try await dash.fetch("docker.info")
        docker.now = { .now.addingTimeInterval(2 * 60) }
        let containers = try #require(try await dash.runTool("docker_containers"))
        #expect(containers["stale"] == true && containers["refresh"] == ["fetcher": "docker.containers", "input": [:]])
        #expect(try await dash.runTool("docker_info")?["stale"] == false)
    }

    @Test func queryAnswersExpireAfterADay() async throws {
        let (docker, dash, _) = try await hosted()
        _ = try await dash.fetch("docker.inspect", ["id": "web"])
        docker.now = { .now.addingTimeInterval(2 * 86_400) }
        _ = try await dash.fetch("docker.inspect", ["id": " web "])
        let stored = dash.testSynced.records(kind: "docker.inspect", scope: docker.storeScope)
        #expect(stored.count == 1 && stored.first?.value["input"] == ["id": "web"])
    }

    @Test func noToolDashiiGetsTalksToTheEngine() async throws {
        let (docker, dash, _) = try await hosted()
        let values: [String: JSONValue] = ["id": "web", "image": "postgres:16"]
        #expect(await NetworkSentinel.requests(running: docker.tools, values: values) == [])
        for resource in docker.resources { _ = try? await dash.fetch(resource.fetcherName, resource.required.isEmpty ? [:] : .object(values)) }
        #expect(await NetworkSentinel.requests(running: docker.tools, values: values) == [])
    }

    @Test func changesAreTheUsers() async throws {
        let (docker, _, _) = try await hosted()
        let changes = ["docker_container_action", "docker_container_state", "docker_remove_container", "docker_exec", "docker_image_pull", "docker_prune"]
        #expect(docker.tools.filter(\.writesRemotely).map(\.name) == changes)
        #expect(docker.tools.filter(\.requiresApproval).map(\.name) == changes)
        #expect(docker.tools.filter(\.isForDashii).map(\.name) == docker.resources.map(\.readerName))
    }

    @Test func toolsFetchersVerbsAndDatasetsLineUp() async throws {
        let (docker, _, _) = try await hosted()
        #expect(docker.fetchers.map(\.name) == docker.resources.map(\.fetcherName))
        #expect(docker.fetchers.count == 20 && docker.fetchers.allSatisfy { $0.name.hasPrefix("docker.") })
        #expect(docker.verbs.allSatisfy { verb in docker.tools.contains { $0.name == verb.tool } })
        #expect(docker.datasets.map(\.name) == ["docker_events"])
    }

    @Test func eventsDatasetReadsStoredEvents() async throws {
        let (docker, dash, _) = try await hosted()
        let events = try #require(docker.datasets.first)
        #expect(try await events.rows(nil).isEmpty)
        _ = try await dash.fetch("docker.events")
        _ = try await dash.fetch("docker.events", ["since_minutes": 120])
        let rows = try await events.rows(nil)
        // The same events from two overlapping fetches come once, newest first.
        #expect(rows.count == 2 && rows.first?["action"] == "die" && rows.first?["exit_code"] == "137")
        #expect(rows.first?["stale"] == false && rows.first?["synced_at"]?.string != nil)
    }
}
