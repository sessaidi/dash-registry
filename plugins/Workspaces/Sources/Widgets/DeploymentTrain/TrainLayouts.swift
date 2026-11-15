import Charts
import DashKit
import DashKitUI
import SwiftUI

// The Deployment Train widget, one layout per size family. Each takes plain cars, so the gallery
// draws them from samples.

extension TrainCar {
    var tone: Tone { succeeded ? .success : failed ? .danger : .warning }

    /// The glance's headline: what's broken, else what's moving, else all green.
    static func headline(_ cars: [TrainCar]) -> (title: String, tone: Tone) {
        let latest = latestPerWorkspace(cars)
        let failing = latest.filter(\.failed).count
        let running = latest.filter { !$0.failed && !$0.succeeded }.count
        if failing > 0 { return ("\(failing) workspace\(failing == 1 ? "" : "s") failing", .danger) }
        if running > 0 { return ("\(running) deploying", .warning) }
        return ("All green", .success)
    }

    /// The workspaces to show first: failing, then deploying, then the most recent.
    static func mostImportant(_ cars: [TrainCar], limit: Int = 3) -> [TrainCar] {
        func rank(_ car: TrainCar) -> Int { car.failed ? 0 : car.succeeded ? 2 : 1 }
        return Array(latestPerWorkspace(cars).sorted { rank($0) != rank($1) ? rank($0) < rank($1) : $0.at > $1.at }.prefix(limit))
    }
}

/// Picks the train's layout for the widget's size family.
struct TrainContent: View {
    let cars: [TrainCar]
    var selectedID: String? = nil
    var onSelect: ((TrainCar) -> Void)? = nil
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        let selected = cars.first { $0.id == selectedID }
        switch layout.family {
        case .narrow:
            TrainGlance(cars: cars, selectedID: selectedID, onSelect: onSelect)
        case .wide:
            VStack(alignment: .leading, spacing: 8) {
                TrainLanes(cars: cars, selectedID: selectedID, onSelect: onSelect, maxLanes: lanes(in: layout.size.height - 40))
                TrainCarLine(car: selected ?? cars.first)
            }
        case .large:
            VStack(alignment: .leading, spacing: 12) {
                TrainLanes(cars: cars, selectedID: selectedID, onSelect: onSelect, maxLanes: lanes(in: layout.size.height * 0.55))
                    .frame(maxHeight: .infinity)
                HStack(alignment: .top, spacing: 16) {
                    TrainPerDay(cars: cars)
                    Divider()
                    TrainSummary(cars: cars)
                        .frame(width: layout.size.width * 0.2)
                    Divider()
                    TrainCarDetail(car: selected ?? cars.first)
                        .frame(width: layout.size.width * 0.28)
                }
                .frame(height: layout.size.height * 0.4)
            }
        default:
            TrainList(cars: cars, selectedID: selectedID, onSelect: onSelect)
        }
    }

    /// Lanes that fit a height, each about a line and a half of text tall.
    private func lanes(in height: CGFloat) -> Int { max(3, Int(height / 26)) }
}

// MARK: Narrow

/// "1 workspace failing" and the three workspaces that matter most.
struct TrainGlance: View {
    let cars: [TrainCar]
    let selectedID: String?
    let onSelect: ((TrainCar) -> Void)?

    var body: some View {
        let headline = TrainCar.headline(cars)
        let top = TrainCar.mostImportant(cars)
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(headline.title) } icon: { StatusDot(headline.tone) }
                    .font(.title3.weight(.semibold))
                if let last = cars.map(\.at).max() {
                    Text("Last deploy \(last.relative)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ForEach(top) { car in
                ItemRow(car.workspace, subtitle: "\(car.what) · \(car.at.relative)", monospacedTitle: true) {
                    StatusDot(car.tone, help: car.error.isEmpty ? car.statusTitle : car.error)
                } trailing: {
                    if !car.failed && !car.succeeded { ProgressView().controlSize(.mini) }
                }
                .selectableRow(selectedID == car.id) { onSelect?(car) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Wide

/// One lane per workspace on a shared time axis, a dot per deployment coloured by result.
struct TrainLanes: View {
    let cars: [TrainCar]
    let selectedID: String?
    let onSelect: ((TrainCar) -> Void)?
    /// The most recently deployed workspaces get a lane; the rest are left out.
    let maxLanes: Int

    var body: some View {
        let lanes = Array(TrainCar.latestPerWorkspace(cars).map(\.workspace).prefix(maxLanes))
        let shown = cars.filter { lanes.contains($0.workspace) }
        // Days for a week of deploys, hours for a busy afternoon.
        let span = (shown.map(\.at).max() ?? .now).timeIntervalSince(shown.map(\.at).min() ?? .now)
        let format: Date.FormatStyle = span > 2 * 86_400 ? .dateTime.weekday(.abbreviated).day() : .dateTime.hour().minute()
        Chart {
            ForEach(lanes, id: \.self) { lane in
                RuleMark(y: .value("Workspace", lane))
                    .foregroundStyle(.quaternary)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            ForEach(shown) { car in
                PointMark(x: .value("When", car.at), y: .value("Workspace", car.workspace))
                    .foregroundStyle(by: .value("Result", car.statusTitle))
                    .symbolSize(car.id == selectedID ? 180 : 70)
                    .annotation(position: .top, spacing: 2) {
                        if car.id == selectedID {
                            Text(car.version.isEmpty ? car.what : car.version).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
            }
        }
        .chartForegroundStyleScale(["Succeeded": Tone.success.color, "Failed": Tone.danger.color, "Running": Tone.warning.color])
        .chartYScale(domain: lanes)
        .chartXScale(range: .plotDimension(padding: 10))
        .chartYAxis {
            // Each workspace's name sits over its lane.
            AxisMarks(position: .leading) { _ in AxisValueLabel().font(.caption.monospaced()) }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: format)
            }
        }
        .chartLegend(position: .top, alignment: .trailing)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(.rect)
                    .onTapGesture { point in
                        guard let onSelect, let frame = proxy.plotFrame.map({ geometry[$0] }) else { return }
                        let local = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
                        if let car = nearest(to: local, in: shown, proxy: proxy) { onSelect(car) }
                    }
            }
        }
        .accessibilityLabel("Deployments by workspace, \(shown.count) shown")
    }

    /// The deployment drawn closest to a tap in the plot, if it's near enough to mean it.
    private func nearest(to point: CGPoint, in cars: [TrainCar], proxy: ChartProxy) -> TrainCar? {
        let hits = cars.compactMap { car -> (car: TrainCar, distance: CGFloat)? in
            guard let x = proxy.position(forX: car.at), let y = proxy.position(forY: car.workspace) else { return nil }
            return (car, hypot(x - point.x, y - point.y))
        }
        return hits.min { $0.distance < $1.distance }.flatMap { $0.distance < 14 ? $0.car : nil }
    }
}

/// The picked (else latest) deployment on one line, under the lanes.
private struct TrainCarLine: View {
    let car: TrainCar?

    var body: some View {
        if let car {
            HStack(spacing: 8) {
                StatusDot(car.tone, help: car.statusTitle)
                Text(car.workspace).font(.caption.monospaced().weight(.semibold))
                Text(car.title)
                if !car.version.isEmpty { Text(car.version).font(.caption.monospaced()).foregroundStyle(.secondary) }
                Label(car.by, systemImage: "person").foregroundStyle(.secondary)
                Text(car.at, format: .relative(presentation: .named)).foregroundStyle(.secondary)
                if !car.error.isEmpty { Text(car.error).foregroundStyle(Tone.danger.color).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .lineLimit(1)
        }
    }
}

// MARK: Large

/// Deployments per day over the last two weeks, stacked by result.
struct TrainPerDay: View {
    let cars: [TrainCar]

    var body: some View {
        let since = Calendar.current.startOfDay(for: .now.addingTimeInterval(-13 * 86_400))
        let recent = cars.filter { $0.at >= since }
        VStack(alignment: .leading, spacing: 6) {
            Text("Deploys per day").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Chart(recent) { car in
                BarMark(x: .value("Day", car.at, unit: .day), y: .value("Deploys", 1))
                    .foregroundStyle(by: .value("Result", car.statusTitle))
            }
            .chartForegroundStyleScale(["Succeeded": Tone.success.color, "Failed": Tone.danger.color, "Running": Tone.warning.color])
            .chartXScale(domain: since...Calendar.current.startOfDay(for: .now).addingTimeInterval(86_400))
            .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
            .chartLegend(.hidden)
        }
    }
}

/// Success rate, typical duration, and how many workspaces are failing.
private struct TrainSummary: View {
    let cars: [TrainCar]

    var body: some View {
        let finished = cars.filter { $0.failed || $0.succeeded }
        let rate = finished.isEmpty ? nil : Double(finished.filter(\.succeeded).count) / Double(finished.count)
        let durations = cars.compactMap(\.duration).sorted()
        let failing = TrainCar.latestPerWorkspace(cars).filter(\.failed).count
        VStack(alignment: .leading, spacing: 10) {
            MetricView(rate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—", label: "succeeded",
                       tone: (rate ?? 1) >= 0.9 ? .success : (rate ?? 1) >= 0.7 ? .warning : .danger)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Deploys").foregroundStyle(.secondary)
                    Text("\(cars.count)").monospacedDigit()
                }
                GridRow {
                    Text("Median").foregroundStyle(.secondary)
                    Text(durations.isEmpty ? "—" : Duration.seconds(durations[durations.count / 2]).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
                }
                GridRow {
                    Text("Failing").foregroundStyle(.secondary)
                    Text("\(failing)").monospacedDigit().foregroundStyle(failing > 0 ? Tone.danger.color : .primary)
                }
            }
            .font(.caption)
        }
    }
}

/// Everything about one deployment: what, from where, by whom, how long, and why it failed.
private struct TrainCarDetail: View {
    let car: TrainCar?

    var body: some View {
        if let car {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(car.workspace).font(.callout.monospaced().weight(.semibold)).lineLimit(1)
                    Badge(car.statusTitle, tone: car.tone)
                }
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    row("What", car.title)
                    if !car.version.isEmpty { row("Version", car.version) }
                    if !car.branch.isEmpty { row("Branch", car.branch) }
                    row("By", car.by)
                    row("When", car.at.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    if let duration = car.duration { row("Took", Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))) }
                }
                .font(.caption)
                if !car.error.isEmpty {
                    Label(car.error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Tone.danger.color).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).lineLimit(1).truncationMode(.middle)
        }
    }
}
