import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The Containers feature: a dashboard widget of local containers, refreshed every 15 s,
/// and activity when a container exits unexpectedly or turns unhealthy.
@MainActor
@Observable
final class DockerContainersFeature: DashExtension {
    let id = "docker-containers"
    let name = "Containers"
    let systemImage = "shippingbox.fill"
    let metadata = ExtensionMetadata(
        version: "1.1.0", author: .dash,
        summary: "A dashboard widget of local Docker containers, with alerts when one crashes or turns unhealthy.",
        category: .cloud, tags: ["docker", "containers"])
    let requires = ["docker"]

    static let interval: Duration = .seconds(15)

    private(set) var containers: [DockerContainer] = []
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var loading = false
    @ObservationIgnored private weak var host: (any ExtensionContext)?
    @ObservationIgnored private var poll: Task<Void, Never>?

    var widgets: [WidgetType] { [WidgetType(ContainersWidget.self)] }

    var integration: DockerIntegration? { host?.integration(DockerIntegration.self) }

    func start(host: any ExtensionContext) {
        self.host = host
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    func refresh() async {
        guard let connection = host?.integration("docker")?.connection else {
            error = "No Docker socket found."
            return
        }
        loading = true
        defer { loading = false }
        do {
            let current = DockerContainer.list(try await connection.get("/containers/json?all=1", service: "Docker"))
            if lastUpdated != nil, let host {
                let intentional = integration?.intentionalReferences ?? []
                for event in ContainerChanges.events(previous: containers, current: current, intentional: intentional) {
                    host.emit(event.kind, from: self, title: event.title, detail: event.detail, importance: event.importance)
                }
            }
            containers = current
            error = nil
            lastUpdated = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ContainersWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var showStopped: Bool = true
    }

    static var kind: String { "docker.containers" }
    static var displayName: String { "Containers" }
    static var summary: String { "Local Docker containers with their state and health." }
    static var systemImage: String { "shippingbox.fill" }
    static var defaultConfig: Config { Config() }
    static var configSchema: JSONValue {
        ["type": "object", "properties": ["showStopped": JSONSchema.boolean("Also list stopped containers.")]]
    }

    static let queryFields = DockerContainer.queryFields

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        ContainersView(showStopped: config.wrappedValue.showStopped, host: context.host,
                       query: context.query(fields: DockerContainer.queryFields), queryText: context.queryText)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Show stopped containers", isOn: config.showStopped)
    }

    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)

    /// Sample containers for the widget gallery (never the Docker socket).
    static func preview(config: Config) -> some View {
        let samples: [(String, String, Tone, String)] = [
            ("api", "ghcr.io/acme/api:1.42 · Up 3 hours", .success, "healthy"),
            ("postgres", "postgres:16 · Up 3 hours", .success, "healthy"),
            ("worker", "ghcr.io/acme/worker:1.42 · Restarting (1)", .warning, "restarting"),
            ("migrations", "ghcr.io/acme/api:1.42 · Exited (1) 2 minutes ago", .danger, "exited 1"),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(samples, id: \.0) { name, subtitle, tone, badge in
                ItemRow(name, subtitle: subtitle, leading: { StatusDot(tone) }, trailing: { Badge(badge, tone: tone) })
            }
        }
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let feature = context.host.ext(DockerContainersFeature.self) else { return .null }
        let shown = feature.containers.filter { config.showStopped || $0.state == "running" }
        return ["containers": .array(shown.map(\.json)), "error": feature.error.map { .string($0) } ?? .null]
    }
}

struct ContainersView: View {
    let showStopped: Bool
    let host: any ExtensionContext
    /// The widget's DashQL query (its query bar), applied after "show stopped".
    var query: WidgetQuery?
    var queryText = ""
    @State private var queryIDs: [String]?

    var body: some View {
        if let feature = host.ext(DockerContainersFeature.self) {
            content(feature)
        } else {
            StateView(.needsConnection(names: ["Docker"]), action: ("Open Extensions", { host.openManager("docker") }))
        }
    }

    @ViewBuilder
    private func content(_ feature: DockerContainersFeature) -> some View {
        let all = feature.containers
            .filter { showStopped || $0.state == "running" }
            .sorted { ($0.stateRank, $0.name) < ($1.stateRank, $1.name) }
        let shown = QueryRows.ordered(all, by: queryIDs)
        Group {
            if feature.lastUpdated == nil {
                if let error = feature.error {
                    StateView(.failed(message: error), action: ("Retry", { Task { await feature.refresh() } }))
                } else {
                    StateView(.loading("Loading containers…"))
                }
            } else if shown.isEmpty {
                StateView(.empty(title: "No containers", systemImage: "shippingbox", message: showStopped ? nil : "Nothing is running."))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    QueryCount(shown: shown.count, total: all.count, query: queryText)
                    List(shown) { container in
                        ItemRow(container.name, subtitle: "\(container.image) · \(container.status)", leading: {
                            StatusDot(container.tone, help: container.state)
                        }, trailing: {
                            Badge(container.badgeText, tone: container.tone)
                        })
                    }
                    .listStyle(.plain)
                    if let error = feature.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
        .task(id: QueryRows.key(queryText, all, row: \.queryRow)) {
            queryIDs = await QueryRows.ids(query, all, row: \.queryRow)
        }
    }
}

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
}
