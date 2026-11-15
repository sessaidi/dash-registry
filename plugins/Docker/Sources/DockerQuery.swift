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

extension DockerContainersFeature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "containers", summary: "Local Docker containers, running and stopped.", fields: DockerContainer.queryFields) { [weak self] _ in
            (self?.containers ?? []).map(\.queryRow)
        }]
    }
}
