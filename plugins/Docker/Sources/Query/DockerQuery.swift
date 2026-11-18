import DashKit
import Foundation

/// Docker containers for DashQL: the `containers` dataset and the Containers widget's query bar.
extension DockerContainer {
    static let queryFields: [QueryDataset.Field] = [
        .init("id", "string", "Short container id"),
        .init("name", "string", "Container name"),
        .init("image", "string", "Image, e.g. postgres:16"),
        .init("state", "string", "created, running, paused, restarting, removing, exited, dead"),
        .init("status", "string", "Docker's status line, e.g. Up 3 hours (healthy)"),
        .init("health", "string", "healthy, unhealthy or starting"),
        .init("exit_code", "number", "Exit code when exited", aliases: ["exit"]),
    ]

    var queryRow: JSONValue {
        [
            "id": .string(shortID), "name": .string(name), "image": .string(image), "state": .string(state), "status": .string(status),
            "health": health.queryValue, "exit_code": exitCode.map { .number(Double($0)) } ?? .null,
        ]
    }
}

/// What DashQL reads from the engine's stored answers: the events Dash fetched, one row each.
extension DockerIntegration {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "docker_events", summary: "Docker engine events Dash fetched (data_fetch docker.events), newest first.",
                      fields: [.init("time", .date), .init("type"), .init("action"), .init("name", "string", "Container, image, volume or network"),
                               .init("image"), .init("exit_code", "string", "Exit code when a container died"),
                               .init("synced_at", .date, "When Dash fetched it"),
                               .init("stale", .bool, "Older than its freshness window: fetch again for current data")]) { [weak self] _ in
            (self?.storedEventRows() ?? []).sorted { ($0["time"]?.string ?? "") > ($1["time"]?.string ?? "") }
        }]
    }
}

extension DockerContainersFeature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "containers", aliases: ["docker"], summary: "Local Docker containers, running and stopped.", fields: DockerContainer.queryFields) { [weak self] _ in
            (self?.containers ?? []).map(\.queryRow)
        }]
    }
}
