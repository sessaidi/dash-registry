import DashKit
import DashKitUI
import SwiftUI

/// Datadog Monitors: the monitors not OK, worst first, with a detail pane on wide sizes.
struct DatadogMonitorsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// Only monitors whose name or tags contain this.
        var filter: String = ""
        var showWarn: Bool = true
        var showNoData: Bool = true
    }

    static var kind: String { "datadog.monitors" }
    static var displayName: String { "Datadog Monitors" }
    static var summary: String { "Datadog monitors in Alert, Warn or No Data, worst first." }
    static var systemImage: String { "bell.badge" }
    static var defaultConfig: Config { Config() }
    static let sizeLimits = GridLimits(minW: 2, minH: 3, maxW: 12, maxH: 20)
    static var configSchema: JSONValue {
        ["type": "object", "properties": [
            "filter": JSONSchema.string("Only monitors whose name or tags contain this, e.g. service:api."),
            "showWarn": JSONSchema.boolean("Include monitors in Warn."),
            "showNoData": JSONSchema.boolean("Include monitors in No Data."),
        ]]
    }

    static let actions = [
        WidgetAction(name: "filter", description: "Show only monitors whose name or tags contain a text (empty shows all). Temporary: the widget's saved filter stays.",
                     properties: ["text": JSONSchema.string("Text, e.g. service:api or checkout.")], required: ["text"]),
        WidgetAction(name: "select", description: "Select a monitor so its detail shows (wide sizes); linked widgets follow the selection.",
                     properties: ["id": JSONSchema.integer("Monitor id.")], required: ["id"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected monitor."),
        WidgetAction(name: "refresh", description: "Check Datadog now."),
    ]

    static let queryFields = DatadogMonitor.queryFields

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        MonitorsView(settings: config, host: context.host, query: context.query(fields: DatadogMonitor.queryFields), queryText: context.queryText)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        TextField("Filter", text: config.filter, prompt: Text("service:api"))
        Toggle("Show Warn", isOn: config.showWarn)
        Toggle("Show No Data", isOn: config.showNoData)
    }

    static func preview(config: Config) -> some View {
        MonitorsPreview(monitors: shown(DatadogMonitor.sample, config))
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let feature = context.host.ext(DatadogMonitorsFeature.self) else { return .null }
        return ["monitors": .array(shown(feature.monitors, config).map(\.json)), "error": feature.error.map { .string($0) } ?? .null,
                "updated": feature.lastUpdated.map { .string($0.ISO8601Format()) } ?? .null]
    }

    static func shown(_ monitors: [DatadogMonitor], _ config: Config) -> [DatadogMonitor] {
        let filter = config.filter.trimmingCharacters(in: .whitespaces).lowercased()
        return monitors.filter { monitor in
            (config.showWarn || monitor.severity != 1) && (config.showNoData || monitor.severity != 2)
                && (filter.isEmpty || monitor.name.lowercased().contains(filter) || monitor.tags.contains { $0.lowercased().contains(filter) })
        }
    }
}

/// The sample monitors in the live widget's responsive layout; clicking selects, as on the dashboard.
private struct MonitorsPreview: View {
    let monitors: [DatadogMonitor]
    @State private var selected: Int?

    var body: some View {
        MonitorsContent(monitors: monitors, total: monitors.count, selected: $selected)
    }
}
