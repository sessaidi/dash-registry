import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The Monitors feature: Datadog monitors that aren't OK, refreshed every minute, with activity
/// when one starts alerting.
@MainActor
@Observable
final class DatadogMonitorsFeature: DashExtension {
    let id = "datadog-monitors"
    let name = "Datadog Monitors"
    let systemImage = "bell.badge"
    let metadata = ExtensionMetadata(
        version: "1.0.0", author: .dash,
        summary: "A dashboard widget of the Datadog monitors in Alert, Warn or No Data, with activity when one starts alerting.",
        category: .monitoring, tags: ["datadog", "monitors", "alerts"], minimumDashKit: "2.0.0")
    let requires = ["datadog"]

    static let interval: Duration = .seconds(60)

    private(set) var monitors: [DatadogMonitor] = []
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var loading = false
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var poll: Task<Void, Never>?

    var widgets: [WidgetType] { [WidgetType(DatadogMonitorsWidget.self)] }

    var datadog: DatadogIntegration? { host?.integration(DatadogIntegration.self) }

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
        guard let datadog, datadog.isConnected else {
            error = nil
            monitors = []
            return
        }
        loading = true
        defer { loading = false }
        do {
            let current = DatadogMonitor.list(try await datadog.get("/api/v1/monitor/search", ["query": #"status:(alert OR warn OR "no data")"#, "per_page": "100"]))
                .sorted { ($0.severity, $0.name) < ($1.severity, $1.name) }
            // A monitor that wasn't alerting at the last check and is now.
            if lastUpdated != nil, let host {
                let before = Set(monitors.filter { $0.severity == 0 }.map(\.id))
                for monitor in current where monitor.severity == 0 && !before.contains(monitor.id) {
                    host.emit("datadog.alert", from: self, title: "Datadog: \(monitor.name) is alerting",
                              link: monitorURL(monitor)?.absoluteString, importance: .notable)
                }
            }
            monitors = current
            error = nil
            lastUpdated = .now
        } catch {
            self.error = error.localizedDescription
        }
    }

    func monitorURL(_ monitor: DatadogMonitor) -> URL? {
        datadog.map { $0.appURL.appending(path: "monitors/\(monitor.id)") }
    }
}

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
        MonitorsList(monitors: [
            DatadogMonitor(id: 1, name: "API p99 latency above 800 ms", status: "Alert", type: "metric alert", tags: ["service:api"], lastTriggered: .now.addingTimeInterval(-600)),
            DatadogMonitor(id: 2, name: "Checkout error rate", status: "Warn", type: "query alert", tags: ["service:checkout"], lastTriggered: .now.addingTimeInterval(-3_600)),
            DatadogMonitor(id: 3, name: "Worker heartbeat", status: "No Data", type: "service check", tags: ["service:worker"], lastTriggered: nil),
        ], selected: .constant(nil), open: { _ in })
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

private struct MonitorsView: View {
    /// The widget's saved settings.
    @Binding var settings: DatadogMonitorsWidget.Config
    /// What Dashii's filter action changed for now; the saved filter stays, and this resets when
    /// the settings change.
    @State private var override: DatadogMonitorsWidget.Config?
    /// The settings with Dashii's temporary filter on top.
    private var config: DatadogMonitorsWidget.Config { override ?? settings }
    let host: any ExtensionContext
    /// The widget's DashQL query (its query bar), applied after the settings' filters.
    let query: WidgetQuery?
    let queryText: String
    @Environment(\.widgetLayout) private var layout
    @State private var selected: Int?
    @State private var queryIDs: [Int]?

    var body: some View {
        Group {
            if let feature = host.ext(DatadogMonitorsFeature.self) {
                content(feature)
                    .onChange(of: settings) { override = nil }
                    .onExitCommand { selected = nil }
                    .reportsSelection(selected.flatMap { id in feature.monitors.first { $0.id == id }.map { $0.queryRow(url: feature.monitorURL($0)) } })
                    .reportsWidgetState(["filter": .string(config.filter), "selected": selected.map { .number(Double($0)) } ?? .null,
                                         "temporary_changes": .bool(override != nil),
                                         "layout": .string(layout.family.rawValue), "query": queryText.isEmpty ? .null : .string(queryText)])
                    .task(id: QueryRows.key(queryText, DatadogMonitorsWidget.shown(feature.monitors, config)) { $0.queryRow(url: feature.monitorURL($0)) }) {
                        queryIDs = await QueryRows.ids(query, DatadogMonitorsWidget.shown(feature.monitors, config)) { $0.queryRow(url: feature.monitorURL($0)) }
                    }
                    .handlesWidgetActions { name, input in
                        switch name {
                        case "filter":
                            var view = config
                            view.filter = input["text"]?.string ?? ""
                            override = view == settings ? nil : view
                            return ["shown": .number(Double(DatadogMonitorsWidget.shown(feature.monitors, view).count))]
                        case "clear_selection":
                            selected = nil
                            return "cleared"
                        case "select":
                            guard let id = input["id"]?.int, feature.monitors.contains(where: { $0.id == id }) else { throw ToolError("No monitor with that id is shown.") }
                            selected = id
                            return "selected"
                        case "refresh":
                            await feature.refresh()
                            return ["monitors": .number(Double(feature.monitors.count))]
                        default:
                            throw ToolError("Unknown action \(name).")
                        }
                    }
            } else {
                StateView(.needsConnection(names: ["Datadog"]), action: ("Connect…", { host.openManager("datadog") }))
            }
        }
    }

    @ViewBuilder
    private func content(_ feature: DatadogMonitorsFeature) -> some View {
        let filtered = DatadogMonitorsWidget.shown(feature.monitors, config)
        let shown = QueryRows.ordered(filtered, by: queryIDs)
        if let error = feature.error, feature.monitors.isEmpty {
            StateView(.failed(message: error))
        } else if feature.lastUpdated == nil {
            StateView(.loading("Checking monitors…"))
        } else if shown.isEmpty {
            StateView(.empty(title: "All clear", systemImage: "checkmark.seal", message: config.filter.isEmpty ? "No monitor is alerting." : "Nothing matches “\(config.filter)”."))
        } else if layout.family == .narrow {
            VStack(alignment: .leading, spacing: 4) {
                QueryCount(shown: shown.count, total: filtered.count, query: queryText)
                MonitorCounts(monitors: shown)
            }
        } else if layout.family == .large || layout.family == .wide, let monitor = shown.first(where: { $0.id == selected }) {
            HStack(alignment: .top, spacing: 12) {
                MonitorsList(monitors: shown, selected: $selected, open: open(feature))
                MonitorDetail(monitor: monitor, url: feature.monitorURL(monitor))
                    .frame(width: min(320, layout.size.width * 0.4))
            }
        } else {
            MonitorsList(monitors: shown, selected: $selected, open: open(feature))
        }
    }

    private func open(_ feature: DatadogMonitorsFeature) -> (DatadogMonitor) -> Void {
        { monitor in if let url = feature.monitorURL(monitor) { NSWorkspace.shared.open(url) } }
    }
}

private struct MonitorCounts: View {
    let monitors: [DatadogMonitor]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                MetricView("\(monitors.count { $0.severity == 0 })", label: "Alert", tone: .danger)
                MetricView("\(monitors.count { $0.severity == 1 })", label: "Warn", tone: .warning)
                MetricView("\(monitors.count { $0.severity == 2 })", label: "No data", tone: .neutral)
            }
            if let worst = monitors.first {
                Text(worst.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MonitorsList: View {
    let monitors: [DatadogMonitor]
    @Binding var selected: Int?
    let open: (DatadogMonitor) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(monitors) { monitor in
                    ItemRow(monitor.name, subtitle: subtitle(monitor),
                            leading: { StatusDot(tone(monitor)) },
                            trailing: { Badge(monitor.status, tone: tone(monitor)) })
                        .padding(4)
                        .background(selected == monitor.id ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                        .onTapGesture { selected = selected == monitor.id ? nil : monitor.id }
                        .onTapGesture(count: 2) { open(monitor) }
                        .contextMenu { Button("Open in Datadog", systemImage: "safari") { open(monitor) } }
                }
            }
        }
    }

    private func subtitle(_ monitor: DatadogMonitor) -> String {
        ([monitor.type] + monitor.tags.prefix(2) + [monitor.lastTriggered.map { "since \($0.relative)" }].compactMap { $0 })
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct MonitorDetail: View {
    let monitor: DatadogMonitor
    let url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monitor.name).font(.headline)
            Badge(monitor.status, tone: tone(monitor))
            LabeledContent("Type", value: monitor.type)
            if let since = monitor.lastTriggered { LabeledContent("Triggered") { RelativeTime(since) } }
            if !monitor.tags.isEmpty {
                Text(monitor.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            if let url { Link("Open in Datadog", destination: url).font(.callout) }
            Spacer()
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }
}

private func tone(_ monitor: DatadogMonitor) -> Tone {
    switch monitor.severity {
    case 0: .danger
    case 1: .warning
    case 2: .neutral
    default: .success
    }
}
