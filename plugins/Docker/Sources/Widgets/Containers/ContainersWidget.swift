import DashKit
import DashKitUI
import SwiftUI

/// Containers: local Docker containers with their state and health.
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

    /// Sample containers for the widget gallery (never the Docker socket), in the same
    /// responsive layout as the live widget.
    static func preview(config: Config) -> some View {
        let samples = DockerContainer.samples
            .filter { config.showStopped || $0.state == "running" }
            .sorted { ($0.stateRank, $0.name) < ($1.stateRank, $1.name) }
        return ContainersContent(containers: samples, total: samples.count)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let feature = context.host.ext(DockerContainersFeature.self) else { return .null }
        let shown = feature.containers.filter { config.showStopped || $0.state == "running" }
        return ["containers": .array(shown.map(\.json)), "error": feature.error.map { .string($0) } ?? .null]
    }
}
