import DashKit
import Foundation
import Testing

@Suite("Docker tools")
struct DockerToolsTests {
    @MainActor @Test func toolNamesAndApprovals() {
        let docker = DockerIntegration()
        #expect(docker.tools.map(\.name) == [
            "docker_containers", "docker_inspect", "docker_logs",
            "docker_info", "docker_find_containers", "docker_compose_projects", "docker_stats", "docker_top", "docker_logs_search",
            "docker_health", "docker_env_names", "docker_ports", "docker_diff", "docker_images", "docker_image_inspect",
            "docker_image_history", "docker_volumes", "docker_networks", "docker_disk_usage", "docker_events",
            "docker_container_action", "docker_container_state", "docker_remove_container", "docker_exec", "docker_image_pull", "docker_prune",
        ])
        #expect(docker.tools.filter(\.requiresApproval).map(\.name) == [
            "docker_container_action", "docker_container_state", "docker_remove_container", "docker_exec", "docker_image_pull", "docker_prune",
        ])
    }

    @MainActor @Test func metadata() {
        let docker = DockerIntegration()
        #expect(docker.metadata.version == "1.7.0" && docker.metadata.minimumDashKit == "2.4.0")
    }

    @Test func filtersAreEncodedJSON() throws {
        #expect(DockerIntegration.filtersQuery([:]) == nil)
        #expect(DockerIntegration.filtersQuery(["label": []]) == nil)
        let query = try #require(DockerIntegration.filtersQuery(["status": ["running"]]))
        #expect(query.removingPercentEncoding == #"filters={"status":["running"]}"#)
    }

    @Test func statsLikeTheCLI() {
        let stats: JSONValue = [
            "name": "/web",
            "cpu_stats": ["cpu_usage": ["total_usage": 400], "system_cpu_usage": 2000, "online_cpus": 4],
            "precpu_stats": ["cpu_usage": ["total_usage": 200], "system_cpu_usage": 1000],
            "memory_stats": ["usage": 104_857_600, "limit": 1_073_741_824, "stats": ["inactive_file": 52_428_800]],
            "networks": ["eth0": ["rx_bytes": 2048, "tx_bytes": 1024]],
            "blkio_stats": ["io_service_bytes_recursive": [["op": "read", "value": 1_048_576], ["op": "write", "value": 512]]],
            "pids_stats": ["current": 7],
        ]
        let summary = DockerIntegration.statsSummary(stats)
        #expect(summary["name"] == "web")
        #expect(summary["cpu_percent"] == 80)
        #expect(summary["memory"] == "50.0MiB / 1.0GiB")
        #expect(summary["memory_percent"] == 4.88)
        #expect(summary["network_rx_tx"] == "2.0KiB / 1.0KiB")
        #expect(summary["block_read_write"] == "1.0MiB / 512B")
        #expect(summary["pids"] == 7)
    }

    @Test func imagesAndDangling() {
        let image: JSONValue = ["Id": "sha256:0123456789abcdef", "RepoTags": ["<none>:<none>"], "Size": 2048, "Created": 0, "Containers": 0]
        let summary = DockerIntegration.imageSummary(image)
        #expect(summary["id"] == "0123456789ab")
        #expect(summary["dangling"] == true)
        #expect(summary["size"] == "2.0KiB")
    }

    @Test func composeGrouping() {
        func container(_ name: String, _ project: String?, _ service: String, _ state: String) -> JSONValue {
            var labels: [String: JSONValue] = ["com.docker.compose.service": .string(service)]
            if let project { labels["com.docker.compose.project"] = .string(project) }
            return ["Id": .string(name + "000000000000"), "Names": [.string("/" + name)], "Image": "x", "State": .string(state), "Status": "", "Labels": .object(labels)]
        }
        let projects = DockerIntegration.composeProjects([container("api-1", "shop", "api", "running"), container("db-1", "shop", "db", "exited"),
                                                          container("solo", nil, "x", "running")])
        #expect(projects.array?.count == 1)
        #expect(projects[0]?["project"] == "shop")
        #expect(projects[0]?["running"] == "1/2")
        #expect(projects[0]?["services"]?["db"]?[0]?["name"] == "db-1")
    }

    @Test func eventsParseOnePerLine() {
        let data = Data("""
            {"Type":"container","Action":"die","time":0,"Actor":{"Attributes":{"name":"web","image":"nginx","exitCode":"137"}}}
            not json
            {"Type":"image","Action":"pull","time":60,"Actor":{"Attributes":{"name":"redis:7"}}}
            """.utf8)
        let events = DockerIntegration.eventLines(data)
        #expect(events.count == 2)
        #expect(events[0]["action"] == "die" && events[0]["exit_code"] == "137")
        #expect(events[1]["name"] == "redis:7")
    }

    @Test func diskUsageTotals() {
        let df: JSONValue = ["Images": [["Size": 1024, "Containers": 0], ["Size": 1024, "Containers": 2]], "Containers": [["SizeRw": 512]],
                             "Volumes": [["UsageData": ["Size": -1]], ["UsageData": ["Size": 2048]]], "BuildCache": [], "LayersSize": 2048]
        let usage = DockerIntegration.diskUsage(df)
        #expect(usage["images"]?["size"] == "2.0KiB" && usage["images"]?["unused"] == 1)
        #expect(usage["volumes"]?["size"] == "2.0KiB")
        #expect(usage["containers"]?["writable_layers"] == "512B")
    }

    @Test func objectPathsRejectTraversal() throws {
        #expect(try DockerIntegration.objectPath("images", "ghcr.io/org/app:1.2") == "/images/ghcr.io%2Forg%2Fapp%3A1.2/json")
        #expect(throws: ToolError.self) { try DockerIntegration.objectPath("images", "../containers") }
        #expect(throws: ToolError.self) { try DockerIntegration.objectPath("volumes", "a b") }
    }

    @Test func bytesFormatting() {
        #expect(DockerIntegration.bytes(0) == "0B")
        #expect(DockerIntegration.bytes(1536) == "1.5KiB")
        #expect(DockerIntegration.bytes(3 * 1_073_741_824) == "3.0GiB")
    }

    /// Opt-in: DASH_DOCKER_LIVE=<socket path> runs every read-only tool against a real engine.
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["DASH_DOCKER_LIVE"] != nil))
    func readOnlyToolsAgainstRealEngine() async throws {
        let docker = DockerIntegration()
        docker.socketPreference = ProcessInfo.processInfo.environment["DASH_DOCKER_LIVE"] ?? ""
        defer { docker.socketPreference = "" }
        await docker.verify()
        #expect(docker.isConnected)
        let first = DockerContainer.list(try await docker.connection!.get("/containers/json", service: "Docker")).first
        let image = first?.image ?? "alpine"
        for tool in docker.tools where !tool.requiresApproval {
            var input: JSONValue = [:]
            if tool.name.hasPrefix("docker_image_") { input = ["image": .string(image)] }
            if let first, ["docker_inspect", "docker_logs", "docker_top", "docker_logs_search", "docker_health", "docker_env_names", "docker_diff"].contains(tool.name) {
                input = ["id": .string(first.name)]
            }
            guard !(input == [:] && ["docker_inspect", "docker_logs", "docker_top", "docker_logs_search", "docker_health", "docker_env_names", "docker_diff"].contains(tool.name)) else { continue }
            do {
                let result = try await tool.run(input)
                print("DOCKERLIVE \(tool.name): \(String(result.jsonString().prefix(240)))")
            } catch {
                print("DOCKERLIVE \(tool.name) FAILED: \(error)")
                Issue.record("\(tool.name): \(error)")
            }
        }
    }
}
