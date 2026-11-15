import Charts
import DashKit
import DashKitUI
import SwiftUI

/// The monitors the widget shows, laid out for its size family:
/// - narrow: "2 alerting" and the three worst monitors;
/// - medium: the list, type, service and trigger time on one line;
/// - wide: a table (Status, Monitor, Service, Type, Triggered), with the selected monitor's detail beside it;
/// - large: counts by status, the table, and the selected monitor's detail or a chart by service.
/// The live widget and the gallery preview both render this, so it takes plain data.
struct MonitorsContent: View {
    let monitors: [DatadogMonitor]
    /// How many the settings kept before the query bar (for "12 of 40").
    let total: Int
    var queryText = ""
    @Binding var selected: Int?
    var url: (DatadogMonitor) -> URL? = { _ in nil }
    var open: (DatadogMonitor) -> Void = { _ in }
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            QueryCount(shown: monitors.count, total: total, query: queryText)
            switch layout.family {
            case .narrow:
                MonitorsNarrowView(monitors: monitors, selected: $selected)
            case .wide:
                HStack(alignment: .top, spacing: 12) {
                    MonitorTable(monitors: monitors, selected: $selected, open: open)
                    if let monitor = selectedMonitor {
                        MonitorDetail(monitor: monitor, url: url(monitor))
                            .frame(width: min(300, layout.size.width * 0.35))
                    }
                }
            case .large:
                MonitorsLargeView(monitors: monitors, selected: $selected, selectedMonitor: selectedMonitor, url: url, open: open)
            default:
                MonitorsList(monitors: monitors, selected: $selected, open: open)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var selectedMonitor: DatadogMonitor? { monitors.first { $0.id == selected } }
}

// MARK: - Families

/// Narrow: the verdict with its count, then the three worst monitors.
struct MonitorsNarrowView: View {
    let monitors: [DatadogMonitor]
    @Binding var selected: Int?

    var body: some View {
        let alerting = monitors.count { $0.severity == 0 }
        let warning = monitors.count { $0.severity == 1 }
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusDot(alerting > 0 ? .danger : warning > 0 ? .warning : .neutral)
                Text(alerting > 0 ? "\(alerting) alerting" : warning > 0 ? "\(warning) warning" : "\(monitors.count) no data")
                    .font(.headline).lineLimit(1)
            }
            let others = [alerting > 0 && warning > 0 ? "\(warning) warn" : nil,
                          monitors.count { $0.severity == 2 } > 0 && (alerting > 0 || warning > 0) ? "\(monitors.count { $0.severity == 2 }) no data" : nil]
                .compactMap { $0 }
            if !others.isEmpty {
                Text(others.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(monitors.prefix(3)) { monitor in
                    HStack(spacing: 6) {
                        StatusDot(monitor.tone, help: monitor.status)
                        Text(monitor.name).font(.callout).lineLimit(1).truncationMode(.tail)
                    }
                    .padding(.vertical, 1)
                    .background(selected == monitor.id ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 4))
                    .contentShape(.rect)
                    .onTapGesture { selected = selected == monitor.id ? nil : monitor.id }
                    .help("\(monitor.status) · \(monitor.name)")
                }
            }
        }
    }
}

/// Medium: one row per monitor, its type, service and trigger time on one line.
struct MonitorsList: View {
    let monitors: [DatadogMonitor]
    @Binding var selected: Int?
    let open: (DatadogMonitor) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(monitors) { monitor in
                    ItemRow(monitor.name, subtitle: subtitle(monitor),
                            leading: { StatusDot(monitor.tone) },
                            trailing: { Badge(monitor.status, tone: monitor.tone) })
                        .padding(4)
                        .background(selected == monitor.id ? AnyShapeStyle(.tint.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                        .onTapGesture { selected = selected == monitor.id ? nil : monitor.id }
                        .onTapGesture(count: 2) { open(monitor) }
                        .contextMenu { Button("Open in Datadog", systemImage: "safari") { open(monitor) } }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func subtitle(_ monitor: DatadogMonitor) -> String {
        [monitor.tag("service"), monitor.type, monitor.lastTriggered.map { "since \($0.relative)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Large: counts by status, then the table beside the selected monitor (or a chart by service).
struct MonitorsLargeView: View {
    let monitors: [DatadogMonitor]
    @Binding var selected: Int?
    let selectedMonitor: DatadogMonitor?
    let url: (DatadogMonitor) -> URL?
    let open: (DatadogMonitor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                MetricView("\(monitors.count { $0.severity == 0 })", label: "Alert", tone: .danger)
                MetricView("\(monitors.count { $0.severity == 1 })", label: "Warn", tone: .warning)
                MetricView("\(monitors.count { $0.severity == 2 })", label: "No data")
                MetricView("\(Set(monitors.compactMap { $0.tag("service") }).count)", label: "Services")
            }
            HStack(alignment: .top, spacing: 16) {
                MonitorTable(monitors: monitors, selected: $selected, open: open)
                Group {
                    if let monitor = selectedMonitor {
                        MonitorDetail(monitor: monitor, url: url(monitor))
                    } else {
                        MonitorsByService(monitors: monitors)
                    }
                }
                .frame(width: 280)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

// MARK: - Pieces

/// Monitors as a table: the header and rows share one set of columns.
private struct MonitorTable: View {
    let monitors: [DatadogMonitor]
    @Binding var selected: Int?
    let open: (DatadogMonitor) -> Void
    @State private var hovered: Int?

    var body: some View {
        VStack(spacing: 0) {
            columns(status: AnyView(Text("Status")), name: Text("Monitor"), service: Text("Service"), type: Text("Type"), triggered: AnyView(Text("Triggered")))
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.vertical, 5)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(monitors) { monitor in
                        columns(status: AnyView(Badge(monitor.status, tone: monitor.tone)),
                                name: Text(monitor.name),
                                service: Text(monitor.tag("service") ?? "—").foregroundStyle(.secondary),
                                type: Text(monitor.type).foregroundStyle(.secondary),
                                triggered: AnyView(Group {
                                    if let since = monitor.lastTriggered { RelativeTime(since) } else { Text("—") }
                                }.foregroundStyle(.secondary)))
                            .font(.callout)
                            .padding(.vertical, 5)
                            .background(selected == monitor.id ? AnyShapeStyle(.tint.opacity(0.18))
                                        : hovered == monitor.id ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear),
                                        in: .rect(cornerRadius: 6))
                            .contentShape(.rect)
                            .onHover { hovered = $0 ? monitor.id : (hovered == monitor.id ? nil : hovered) }
                            .onTapGesture { selected = selected == monitor.id ? nil : monitor.id }
                            .onTapGesture(count: 2) { open(monitor) }
                            .contextMenu { Button("Open in Datadog", systemImage: "safari") { open(monitor) } }
                            .help(monitor.tags.joined(separator: ", "))
                        Divider().opacity(0.5)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func columns(status: AnyView, name: Text, service: Text, type: Text, triggered: AnyView) -> some View {
        HStack(spacing: 12) {
            status.frame(width: 64, alignment: .leading)
            name.lineLimit(1).truncationMode(.tail).frame(minWidth: 140, maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            service.lineLimit(1).frame(width: 90, alignment: .leading)
            type.lineLimit(1).frame(width: 96, alignment: .leading)
            triggered.lineLimit(1).frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 8)
    }
}

/// How many monitors each service has not OK, by status.
private struct MonitorsByService: View {
    let monitors: [DatadogMonitor]

    var body: some View {
        let services = Dictionary(grouping: monitors) { $0.tag("service") ?? "untagged" }
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .prefix(8)
        VStack(alignment: .leading, spacing: 8) {
            Text("By service").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(services), id: \.key) { service, monitors in
                    ForEach(monitors) { monitor in
                        BarMark(x: .value("Monitors", 1), y: .value("Service", service))
                            .foregroundStyle(by: .value("Status", monitor.chartStatus))
                    }
                }
            }
            .chartForegroundStyleScale(["Alert": Tone.danger.color, "Warn": Tone.warning.color, "No Data": Color.gray, "Other": Tone.info.color])
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(maxHeight: .infinity)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }
}

/// The selected monitor, with a link to Datadog.
private struct MonitorDetail: View {
    let monitor: DatadogMonitor
    let url: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(monitor.name).font(.headline)
            Badge(monitor.status, tone: monitor.tone)
            LabeledContent("Type", value: monitor.type)
            if let service = monitor.tag("service") { LabeledContent("Service", value: service) }
            if let since = monitor.lastTriggered { LabeledContent("Triggered") { RelativeTime(since) } }
            if !monitor.tags.isEmpty {
                Text(monitor.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
            if let url { Link("Open in Datadog", destination: url).font(.callout) }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }
}

extension DatadogMonitor {
    /// The status as one of the chart's four series.
    var chartStatus: String {
        switch severity {
        case 0: "Alert"
        case 1: "Warn"
        case 2: "No Data"
        default: "Other"
        }
    }

    var tone: Tone {
        switch severity {
        case 0: .danger
        case 1: .warning
        case 2: .neutral
        default: .success
        }
    }
}
