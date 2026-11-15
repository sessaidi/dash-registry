import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// The Monitors widget: observes `DatadogMonitorsFeature` (its poller), applies the settings,
/// Dashii's temporary filter and the query bar, and publishes the selection.
struct MonitorsView: View {
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
        } else {
            MonitorsContent(monitors: shown, total: filtered.count, queryText: queryText, selected: $selected,
                            url: { feature.monitorURL($0) }, open: open(feature))
        }
    }

    private func open(_ feature: DatadogMonitorsFeature) -> (DatadogMonitor) -> Void {
        { monitor in if let url = feature.monitorURL(monitor) { NSWorkspace.shared.open(url) } }
    }
}
