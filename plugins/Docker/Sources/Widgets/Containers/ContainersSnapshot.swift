import DashKit
import DashKitUI

/// How a container shows in the widget: its tone and badge.
extension DockerContainer {
    var tone: Tone {
        if health == "unhealthy" { return .danger }
        switch state {
        case "running": return health == "starting" ? .info : .success
        case "restarting", "paused": return .warning
        case "dead": return .danger
        case "exited": return (exitCode ?? 0) == 0 ? .neutral : .danger
        default: return .neutral
        }
    }

    var badgeText: String {
        if let health, state == "running" { return health }
        if state == "exited", let exitCode { return "exited \(exitCode)" }
        return state
    }

    /// Needs a look: unhealthy, crashed (non-zero exit, dead) or stuck restarting.
    var needsAttention: Bool { tone == .danger || tone == .warning }

    /// The status without the state word or health: "3 hours", "2 minutes ago".
    var statusDetail: String {
        var text = status
        for prefix in ["Up ", "Restarting ", "Exited ", "Created", "Paused"] where text.hasPrefix(prefix) {
            text = String(text.dropFirst(prefix.count))
        }
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") { text = String(text[text.index(after: close)...]) }
        if let open = text.range(of: " (") { text = String(text[..<open.lowerBound]) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// Sample containers for the widget gallery (never the Docker socket).
extension DockerContainer {
    static let samples: [DockerContainer] = [
        DockerContainer(id: "9f1c2a7b4e3d5f60718293a4", name: "migrations", image: "ghcr.io/acme/api:1.42", state: "exited", status: "Exited (1) 2 minutes ago"),
        DockerContainer(id: "a41b7c9d2e0f3a5b6c7d8e9f", name: "search", image: "opensearch:2.17", state: "running", status: "Up 40 minutes (unhealthy)"),
        DockerContainer(id: "b72d4e1f9a3c5b7d9e1f2a3b", name: "worker", image: "ghcr.io/acme/worker:1.42", state: "restarting", status: "Restarting (1) 8 seconds ago"),
        DockerContainer(id: "c3e5f7a9b1d3e5f7a9b1c3d5", name: "api", image: "ghcr.io/acme/api:1.42", state: "running", status: "Up 3 hours (healthy)"),
        DockerContainer(id: "d4f6a8b0c2e4f6a8b0c2d4e6", name: "postgres", image: "postgres:16", state: "running", status: "Up 3 hours (healthy)"),
        DockerContainer(id: "e5a7b9c1d3f5a7b9c1d3e5f7", name: "redis", image: "redis:7.4", state: "running", status: "Up 3 hours"),
        DockerContainer(id: "f6b8c0d2e4a6b8c0d2e4f6a8", name: "web", image: "ghcr.io/acme/web:2.8", state: "running", status: "Up 26 minutes (health: starting)"),
        DockerContainer(id: "07c9d1e3f5b7c9d1e3f5a7b9", name: "seed", image: "ghcr.io/acme/api:1.42", state: "exited", status: "Exited (0) 3 hours ago"),
    ]
}
