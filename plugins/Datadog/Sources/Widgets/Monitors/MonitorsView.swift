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

struct MonitorsList: View {
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
