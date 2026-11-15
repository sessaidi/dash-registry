import DashKit
import DashKitUI
import SwiftUI

// MARK: - Widget

struct ReleaseTimelineWidget: DashboardWidget {
    /// Everything here is chosen in the widget's settings; the widget itself only shows it.
    struct Config: Codable, Equatable, Sendable {
        /// A repository id; nil shows every configured repository, one group of lanes each.
        var repository: String?
        /// Days shown when the widget opens; nil is everything.
        var period: Int? = 90
        /// One train (lowercased suffix, "" for the shared one); nil is every train.
        var train: String?
        /// Show the launches/incidents lane.
        var events: Bool = true
    }

    static let kind = "releases.timeline"
    static let displayName = "Release timeline"
    static let summary = "Releases from git tags as eras on one lane per train, with build ticks, hotfixes, today and an events lane. Pinch to zoom, drag to pan, click a release for its builds, commits and tickets. Repository, period and train are set in the widget's settings."
    static let systemImage = "point.bottomleft.forward.to.point.topright.scurvepath"
    static let defaultSize = WidgetSize.wide
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "repository": ["type": "string", "description": "Repository id from Settings › Releases; omit for every repository."],
            "period": ["type": "integer", "description": "Days shown at first (30, 90, 180, 365); omit for all."],
            "train": ["type": "string", "description": "Only this train (eu, us…; \"\" for the shared one); omit for all."],
            "events": ["type": "boolean", "description": "Show the launches/incidents/milestones lane."],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        if let feature = context.host.ext(ReleasesFeature.self) {
            ReleaseTimelineView(feature: feature, host: context.host, config: config.wrappedValue)
        } else {
            StateView(.failed(message: "Releases isn't loaded."))
        }
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        ReleaseTimelineSettings(feature: context.host.ext(ReleasesFeature.self), host: context.host, config: config)
    }

    /// Sample releases for the widget gallery (never git).
    static func preview(config: Config) -> some View {
        let timeline = ReleaseSamples.timeline
        return TimelineChart(model: TimelineModel(timelines: [timeline], events: ReleaseSamples.events, train: nil, showEvents: true),
                             domain: ReleaseSamples.now.addingTimeInterval(-75 * 86_400)...ReleaseSamples.now.addingTimeInterval(3 * 86_400),
                             now: ReleaseSamples.now, compact: false, selected: nil, hovered: nil, query: "")
            .frame(height: 150)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let feature = context.host.ext(ReleasesFeature.self) else { return .null }
        let since = config.period.map { Date.now.addingTimeInterval(-Double($0) * 86_400) }
        return .array(feature.repositories.filter { config.repository == nil || $0.id == config.repository }.compactMap { repository in
            guard let timeline = feature.timelines[repository.id] else { return nil }
            let releases = timeline.releases.filter { release in
                (config.train == nil || release.train == config.train) && (since.map { release.end >= $0 } ?? true)
            }
            return ["repo": .string(repository.name),
                    "live_now": .array(timeline.liveAt(.now).map { ["train": .string(timeline.trainTitle($0.train)), "tag": .string($0.build.tag)] }),
                    "releases": .array(releases.reversed().prefix(60).map { ReleasesFeature.summary($0, timeline) })]
        })
    }
}

/// Repository, period, train and events lane.
private struct ReleaseTimelineSettings: View {
    let feature: ReleasesFeature?
    let host: any ExtensionContext
    @Binding var config: ReleaseTimelineWidget.Config

    var body: some View {
        let repositories = feature?.repositories ?? []
        Section("Source") {
            if repositories.isEmpty {
                LabeledContent("Repository") {
                    Button("Add a repository in Settings…") { host.openManager("releases") }
                }
            } else {
                Picker("Repository", selection: $config.repository) {
                    Text("All repositories").tag(String?.none)
                    ForEach(repositories) { Text($0.name).tag(String?.some($0.id)) }
                }
            }
            Picker("Train", selection: $config.train) {
                Text("All trains").tag(String?.none)
                ForEach(trains, id: \.self) { train in
                    Text(RepositoryTimeline.trainTitle(train, among: trains)).tag(String?.some(train))
                }
            }
        }
        Section("View") {
            Picker("Period", selection: $config.period) {
                Text("All").tag(Int?.none)
                ForEach([365, 180, 90, 30], id: \.self) { Text("Last \($0) days").tag(Int?.some($0)) }
            }
            Toggle("Events lane (launches, incidents, milestones)", isOn: $config.events)
        }
    }

    /// Trains of the chosen repositories.
    private var trains: [String] {
        var trains: [String] = []
        for timeline in feature?.timelines.values.sorted(by: { $0.repository.name < $1.repository.name }) ?? []
        where config.repository == nil || timeline.repository.id == config.repository {
            for train in timeline.trains where !trains.contains(train) { trains.append(train) }
        }
        if let train = config.train, !trains.contains(train) { trains.append(train) }
        return trains
    }
}

// MARK: - Model

/// What the chart draws: lanes top to bottom.
struct TimelineModel {
    struct Lane: Identifiable {
        enum Kind { case events, train(repository: String, train: String) }
        let id: String
        let kind: Kind
        let title: String
        let subtitle: String
        let color: Color
        let releases: [Release]
        let events: [ReleaseEvent]
        /// First lane of a repository's group (draws its name above when there are several).
        var groupTitle: String?
    }

    var lanes: [Lane] = []
    var releases: [Release] { lanes.flatMap(\.releases) }
    var earliest: Date?

    static let palette: [Color] = [.blue, .orange, .teal, .pink, .purple, .green, .brown]

    init(timelines: [RepositoryTimeline], events: [ReleaseEvent], train: String?, showEvents: Bool) {
        if showEvents, !events.isEmpty {
            lanes.append(Lane(id: "events", kind: .events, title: "Events", subtitle: "", color: .secondary, releases: [], events: events))
        }
        for timeline in timelines {
            var first = true
            for (index, name) in timeline.trains.enumerated() where train == nil || train == name {
                let releases = timeline.releases(on: name)
                guard !releases.isEmpty else { continue }
                let color = name.isEmpty && timeline.trains.count > 1 ? Color.gray : Self.palette[index % Self.palette.count]
                let since = releases.first.map { "since " + $0.start.formatted(.dateTime.month(.abbreviated).year()) } ?? ""
                lanes.append(Lane(id: timeline.repository.id + "|" + name, kind: .train(repository: timeline.repository.id, train: name),
                                  title: timeline.trainTitle(name), subtitle: since, color: color, releases: releases, events: [],
                                  groupTitle: first && timelines.count > 1 ? timeline.repository.name : nil))
                first = false
            }
        }
        earliest = (releases.map(\.start) + (showEvents ? events.map(\.date) : [])).min()
    }
}

/// Positions shared by drawing and hit-testing.
struct TimelineLayout {
    let size: CGSize
    let domain: ClosedRange<Date>
    let compact: Bool
    let lanes: [TimelineModel.Lane]

    var labelWidth: CGFloat { compact ? 40 : 92 }
    var axisHeight: CGFloat { 18 }
    var laneHeight: CGFloat { compact ? 24 : 32 }
    var eventsHeight: CGFloat { compact ? 20 : 26 }
    var groupHeight: CGFloat { 14 }
    var gap: CGFloat { 5 }
    var plot: ClosedRange<CGFloat> { labelWidth...max(labelWidth + 40, size.width - 4) }

    func x(_ date: Date) -> CGFloat {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return plot.lowerBound }
        return plot.lowerBound + CGFloat(date.timeIntervalSince(domain.lowerBound) / span) * (plot.upperBound - plot.lowerBound)
    }

    func date(_ x: CGFloat) -> Date {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        return domain.lowerBound.addingTimeInterval(Double((x - plot.lowerBound) / (plot.upperBound - plot.lowerBound)) * span)
    }

    /// Each lane's vertical band.
    var bands: [(lane: TimelineModel.Lane, rect: CGRect)] {
        var y = axisHeight + 2
        return lanes.map { lane in
            if lane.groupTitle != nil { y += groupHeight }
            let height: CGFloat = if case .events = lane.kind { eventsHeight } else { laneHeight }
            defer { y += height + gap }
            return (lane, CGRect(x: plot.lowerBound, y: y, width: plot.upperBound - plot.lowerBound, height: height))
        }
    }

    var height: CGFloat { (bands.last?.rect.maxY ?? axisHeight) + 4 }

    func eraRect(_ release: Release, in band: CGRect) -> CGRect {
        let start = x(release.start)
        return CGRect(x: start, y: band.minY + 2, width: max(1.5, x(release.end) - start), height: band.height - 4)
    }

    func release(at point: CGPoint) -> Release? {
        for (lane, rect) in bands where rect.insetBy(dx: -2, dy: -2).contains(point) {
            // The last era starting before the point, with a little slack for thin ones.
            return lane.releases.last { eraRect($0, in: rect).insetBy(dx: -3, dy: 0).contains(point) }
        }
        return nil
    }

    func event(at point: CGPoint) -> ReleaseEvent? {
        for (lane, rect) in bands where rect.contains(point) {
            return lane.events.min { abs(x($0.date) - point.x) < abs(x($1.date) - point.x) }.flatMap { abs(x($0.date) - point.x) < 8 ? $0 : nil }
        }
        return nil
    }

    /// Axis ticks: days, weeks, months, quarters or years, whichever keeps labels apart.
    func ticks() -> [(date: Date, label: String)] {
        let calendar = Calendar.current
        let width = plot.upperBound - plot.lowerBound
        let days = domain.upperBound.timeIntervalSince(domain.lowerBound) / 86_400
        let fit = max(1, Double(width) / (compact ? 64 : 84))
        let steps: [(Calendar.Component, Int)] = [(.day, 1), (.day, 2), (.weekOfYear, 1), (.weekOfYear, 2), (.month, 1), (.month, 3), (.month, 6), (.year, 1), (.year, 2)]
        let approx: [Calendar.Component: Double] = [.day: 1, .weekOfYear: 7, .month: 30.4, .year: 365]
        let (unit, count) = steps.first { days / (approx[$0.0]! * Double($0.1)) <= fit } ?? (.year, 5)
        var start: Date
        switch unit {
        case .year: start = calendar.dateInterval(of: .year, for: domain.lowerBound)?.start ?? domain.lowerBound
        case .month: start = calendar.dateInterval(of: .month, for: domain.lowerBound)?.start ?? domain.lowerBound
        case .weekOfYear: start = calendar.dateInterval(of: .weekOfYear, for: domain.lowerBound)?.start ?? domain.lowerBound
        default: start = calendar.startOfDay(for: domain.lowerBound)
        }
        var ticks: [(Date, String)] = []
        while start <= domain.upperBound, ticks.count < 60 {
            if start >= domain.lowerBound {
                let label = switch unit {
                case .year: start.formatted(.dateTime.year())
                case .month: calendar.component(.month, from: start) == 1 ? start.formatted(.dateTime.month(.abbreviated).year()) : start.formatted(.dateTime.month(.abbreviated))
                default: start.formatted(.dateTime.month(.abbreviated).day())
                }
                ticks.append((start, label))
            }
            guard let next = calendar.date(byAdding: unit, value: count, to: start) else { break }
            start = next
        }
        return ticks
    }
}

// MARK: - Chart

/// The timeline itself, drawn in one Canvas.
struct TimelineChart: View {
    let model: TimelineModel
    let domain: ClosedRange<Date>
    let now: Date
    let compact: Bool
    let selected: String?
    let hovered: String?
    let query: String

    var body: some View {
        GeometryReader { geometry in
            let layout = TimelineLayout(size: geometry.size, domain: domain, compact: compact, lanes: model.lanes)
            Canvas { context, size in
                draw(&context, layout)
            }
        }
    }

    private func draw(_ context: inout GraphicsContext, _ layout: TimelineLayout) {
        let plot = layout.plot
        let bands = layout.bands
        let bottom = layout.height
        let today = layout.x(now)
        let showToday = plot.contains(today) && !compact
        // Grid and axis; a label that would run into "today" is left out.
        for tick in layout.ticks() {
            let x = layout.x(tick.date)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: layout.axisHeight)); $0.addLine(to: CGPoint(x: x, y: bottom)) },
                           with: .color(.secondary.opacity(0.15)), lineWidth: 1)
            let label = context.resolve(Text(tick.label).font(.caption2).foregroundStyle(.secondary))
            let width = label.measure(in: CGSize(width: 200, height: 20)).width
            if showToday, x + 3 + width > today - 36, x < today + 4 { continue }
            context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
        }
        let plotClip = Path(CGRect(x: plot.lowerBound, y: 0, width: plot.upperBound - plot.lowerBound, height: bottom))
        for (lane, rect) in bands {
            if let group = lane.groupTitle {
                context.draw(Text(group).font(.caption.bold()), at: CGPoint(x: 4, y: rect.minY - layout.groupHeight + 1), anchor: .topLeading)
            }
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.secondary.opacity(0.07)))
            // Lane label.
            let title = Text(lane.title).font(compact ? .caption2.bold() : .caption.bold())
            if compact || lane.subtitle.isEmpty {
                context.draw(title, at: CGPoint(x: 4, y: rect.midY), anchor: .leading)
            } else {
                context.draw(title, at: CGPoint(x: 4, y: rect.midY - 1), anchor: .bottomLeading)
                context.draw(Text(lane.subtitle).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 4, y: rect.midY + 1), anchor: .topLeading)
            }
            var inner = context
            inner.clip(to: plotClip)
            if case .events = lane.kind { drawEvents(&inner, lane, rect, layout) } else { drawEras(&inner, lane, rect, layout) }
        }
        // Today.
        if plot.contains(today) {
            context.stroke(Path { $0.move(to: CGPoint(x: today, y: layout.axisHeight - 2)); $0.addLine(to: CGPoint(x: today, y: bottom)) },
                           with: .color(.red.opacity(0.8)), style: StrokeStyle(lineWidth: 1.2))
            if showToday {
                context.draw(Text("today").font(.caption2).foregroundStyle(.red), at: CGPoint(x: today - 3, y: 2), anchor: .topTrailing)
            }
        }
    }

    private func drawEras(_ context: inout GraphicsContext, _ lane: TimelineModel.Lane, _ band: CGRect, _ layout: TimelineLayout) {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        for release in lane.releases {
            let rect = layout.eraRect(release, in: band)
            guard rect.maxX >= layout.plot.lowerBound - 2, rect.minX <= layout.plot.upperBound + 2 else { continue }
            let dimmed = searching && !release.matches(query)
            let path = Path(roundedRect: rect, cornerRadius: 2)
            let opacity = (release.index % 2 == 0 ? 0.88 : 0.68) * (dimmed ? 0.18 : 1)
            context.fill(path, with: .color(lane.color.opacity(release.isHotfix ? opacity * 0.55 : opacity)))
            if release.isHotfix {
                context.stroke(path, with: .color(lane.color.opacity(dimmed ? 0.3 : 1)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 2]))
            }
            if release.id == selected || release.id == hovered {
                context.stroke(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: 3),
                               with: .color(.primary.opacity(release.id == selected ? 0.9 : 0.45)), lineWidth: release.id == selected ? 2 : 1)
            }
            if searching, !dimmed, rect.width < 6 {
                // A match too thin to see: a dot above it.
                context.fill(Path(ellipseIn: CGRect(x: rect.midX - 2.5, y: band.minY - 3, width: 5, height: 5)), with: .color(.primary))
            }
            // Extra builds: ticks from the top edge; a build tagged after the era ended sits at the bottom.
            for build in release.builds.dropFirst() {
                let x = layout.x(build.date)
                let late = build.date > release.end
                let y0 = late ? band.maxY - 9 : band.minY + 2
                context.stroke(Path { $0.move(to: CGPoint(x: x, y: y0)); $0.addLine(to: CGPoint(x: x, y: y0 + 7)) },
                               with: .color(build.onBase ? Color.primary.opacity(0.55) : .red), lineWidth: 1.5)
            }
            let label = Text(release.shortName).font(.caption2.monospaced()).foregroundStyle(.white)
            let resolved = context.resolve(label)
            let measured = resolved.measure(in: CGSize(width: 400, height: 20))
            // The label goes in the era's visible part (it may start off the left edge).
            let left = max(rect.minX, layout.plot.lowerBound)
            let right = min(rect.maxX, layout.plot.upperBound)
            if right - left > measured.width + 8, !dimmed {
                context.draw(resolved, at: CGPoint(x: left + 4, y: rect.midY), anchor: .leading)
            }
        }
    }

    private func drawEvents(_ context: inout GraphicsContext, _ lane: TimelineModel.Lane, _ band: CGRect, _ layout: TimelineLayout) {
        var lastX = -CGFloat.infinity
        var row = 0
        for event in lane.events {
            let x = layout.x(event.date)
            row = x - lastX < 10 ? (row + 1) % 2 : 0
            lastX = x
            let y = band.midY + (row == 0 ? -3 : 4)
            let color: Color = switch event.kind { case .launch: .green; case .incident: .red; case .milestone: .purple }
            let size: CGFloat = compact ? 7 : 9
            let rect = CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)
            let path: Path = switch event.kind {
            case .launch: Path(ellipseIn: rect)
            case .incident: Path { $0.move(to: CGPoint(x: rect.midX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); $0.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); $0.closeSubpath() }
            case .milestone: Path { $0.move(to: CGPoint(x: rect.midX, y: rect.minY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.midX, y: rect.maxY)); $0.addLine(to: CGPoint(x: rect.minX, y: rect.midY)); $0.closeSubpath() }
            }
            let dimmed = !query.isEmpty && !(event.title + " " + event.note).lowercased().contains(query.lowercased())
            context.fill(path, with: .color(color.opacity(dimmed ? 0.2 : 0.95)))
        }
    }
}

// MARK: - Widget view

struct ReleaseTimelineView: View {
    let feature: ReleasesFeature
    let host: any ExtensionContext
    let config: ReleaseTimelineWidget.Config

    @State private var domain: ClosedRange<Date>?
    @State private var dragStart: ClosedRange<Date>?
    @State private var zoomStart: ClosedRange<Date>?
    @State private var hovered: Release?
    @State private var hoveredEvent: ReleaseEvent?
    @State private var selection: ReleaseSelection?
    @State private var eventSelection: ReleaseEvent?
    @State private var searching = false
    @State private var query = ""

    private var repositories: [RepositoryConfig] {
        feature.repositories.filter { config.repository == nil || $0.id == config.repository }
    }

    private var timelines: [RepositoryTimeline] { repositories.compactMap { feature.timelines[$0.id] } }

    var body: some View {
        if feature.repositories.isEmpty {
            StateView(.empty(title: "No repositories", systemImage: "point.bottomleft.forward.to.point.topright.scurvepath",
                             message: "Add a repository in Settings › Releases."),
                      action: ("Open Settings", { host.openManager("releases") }))
        } else if repositories.isEmpty {
            StateView(.failed(message: "This widget's repository was removed. Pick another in the widget's settings."))
        } else if timelines.isEmpty {
            if let error = repositories.lazy.compactMap({ feature.errors[$0.id] }).first {
                StateView(.failed(message: error), action: ("Retry", { Task { await feature.refresh() } }))
            } else {
                StateView(.loading("Reading release tags…"))
                    .task { if feature.loading.isEmpty { await feature.refresh() } }
            }
        } else {
            content
        }
    }

    private var content: some View {
        let model = TimelineModel(timelines: timelines, events: config.events ? feature.events(for: config.repository) : [],
                                  train: config.train, showEvents: config.events)
        let now = feature.now()
        let full = fullDomain(model, now: now)
        let shown = domain ?? initialDomain(full, now: now)
        return GeometryReader { geometry in
            let compact = geometry.size.width < 420
            let layout = TimelineLayout(size: CGSize(width: geometry.size.width, height: 0), domain: shown, compact: compact, lanes: model.lanes)
            VStack(alignment: .leading, spacing: 6) {
                header(model, compact: compact, now: now, zoomed: domain != nil)
                if model.lanes.isEmpty {
                    StateView(.empty(title: "No release tags", systemImage: "tag",
                                     message: "No tags match \(repositories.map(\.tagPattern).joined(separator: ", ")). Check the tag pattern in Settings › Releases."))
                } else {
                    ScrollView(.vertical) {
                        chart(model, layout: layout, full: full, now: now, compact: compact)
                            .frame(height: layout.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    footer(model, compact: compact, now: now)
                }
            }
        }
        .sheet(item: $selection) { selection in
            ReleaseDetailSheet(feature: feature, repository: selection.repository, releaseID: selection.release)
        }
        .sheet(item: $eventSelection) { event in
            ReleaseEventSheet(event: event, releases: timelines.map { timeline in (timeline, timeline.liveAt(event.date)) })
        }
        .onChange(of: config) { domain = nil }
    }

    private func chart(_ model: TimelineModel, layout: TimelineLayout, full: ClosedRange<Date>, now: Date, compact: Bool) -> some View {
        let shown = layout.domain
        return TimelineChart(model: model, domain: shown, now: now, compact: compact, selected: selection?.release, hovered: hovered?.id, query: searching ? query : "")
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let start = dragStart ?? shown
                    if dragStart == nil { dragStart = shown }
                    let perPoint = start.upperBound.timeIntervalSince(start.lowerBound) / Double(layout.plot.upperBound - layout.plot.lowerBound)
                    domain = clamp(start, shift: -Double(value.translation.width) * perPoint, full: full)
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture()
                .onChanged { value in
                    let start = zoomStart ?? shown
                    if zoomStart == nil { zoomStart = shown }
                    let anchor = TimelineLayout(size: layout.size, domain: start, compact: compact, lanes: model.lanes).date(value.startLocation.x)
                    domain = zoom(start, by: value.magnification, around: anchor, full: full)
                }
                .onEnded { _ in zoomStart = nil })
            .onTapGesture { point in
                if let release = layout.release(at: point) {
                    selection = ReleaseSelection(repository: release.repository, release: release.id)
                } else if let event = layout.event(at: point) {
                    eventSelection = event
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hovered = layout.release(at: point)
                    hoveredEvent = hovered == nil ? layout.event(at: point) : nil
                case .ended:
                    hovered = nil
                    hoveredEvent = nil
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Release timeline, \(model.releases.count) releases")
    }

    // MARK: Header and footer

    private func header(_ model: TimelineModel, compact: Bool, now: Date, zoomed: Bool) -> some View {
        HStack(spacing: 6) {
            if searching {
                TextField("Ticket or text, e.g. LAF-5917", text: $query)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit { revealMatches(model) }
                let hits = query.isEmpty ? 0 : model.releases.filter { $0.matches(query) }.count
                if !query.isEmpty { Text("\(hits)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("\(hits) releases match") }
            } else {
                Text(title(model)).font(.caption.bold()).lineLimit(1)
                if !compact {
                    ForEach(liveNow(now), id: \.id) { live in
                        Badge("\(live.train) \(live.name)", tone: live.hotfix ? .warning : .info, systemImage: "dot.radiowaves.left.and.right")
                            .help("Live now on \(live.train): \(live.tag)")
                    }
                }
            }
            Spacer(minLength: 0)
            if repositories.contains(where: { feature.loading.contains($0.id) }) { ProgressView().controlSize(.mini) }
            if let error = repositories.lazy.compactMap({ feature.errors[$0.id] }).first {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).help(error)
            }
            if zoomed {
                Button { withAnimation(.snappy) { domain = nil } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Back to the widget's period")
            }
            Button { searching.toggle(); if !searching { query = "" } } label: { Image(systemName: searching ? "xmark.circle.fill" : "magnifyingglass") }
                .buttonStyle(.borderless).help(searching ? "Stop searching" : "Search releases by ticket or text")
        }
        .font(.caption)
    }

    private func footer(_ model: TimelineModel, compact: Bool, now: Date) -> some View {
        Group {
            if let hovered {
                Text(hoverLine(hovered, now: now)).lineLimit(1).truncationMode(.tail)
            } else if let hoveredEvent {
                Text("\(hoveredEvent.kind.title) · \(hoveredEvent.date.formatted(date: .abbreviated, time: .omitted)) · \(hoveredEvent.title)").lineLimit(1)
            } else if compact {
                // Narrow: what's live now, in place of the header badges.
                Text(liveNow(now).map { "\($0.train) \($0.name)" }.joined(separator: " · ")).lineLimit(1)
            } else {
                Text("Pinch to zoom, drag to pan, click a release for details.").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func title(_ model: TimelineModel) -> String {
        let count = model.releases.count
        return (repositories.count == 1 ? repositories[0].name + " · " : "") + "\(count) release\(count == 1 ? "" : "s")"
    }

    private struct Live: Identifiable { let id: String; let train: String; let name: String; let tag: String; let hotfix: Bool }

    private func liveNow(_ now: Date) -> [Live] {
        timelines.flatMap { timeline in
            timeline.liveAt(now).filter { config.train == nil || $0.train == config.train }.map { live in
                Live(id: timeline.repository.id + live.train, train: (timelines.count > 1 ? timeline.repository.name + " " : "") + timeline.trainTitle(live.train),
                     name: live.release.shortName, tag: live.build.tag, hotfix: !live.build.onBase)
            }
        }
    }

    private func hoverLine(_ release: Release, now: Date) -> String {
        let until = release.isCurrent ? "today" : release.end.formatted(.dateTime.month(.abbreviated).day())
        var parts = [release.name, release.start.formatted(.dateTime.month(.abbreviated).day()) + " → " + until]
        if release.builds.count > 1 { parts.append("\(release.builds.count) builds") }
        parts.append("\(release.newCommits.count) commits")
        if release.isHotfix { parts.append("hotfix") }
        return parts.joined(separator: " · ")
    }

    // MARK: Zoom and pan

    private func fullDomain(_ model: TimelineModel, now: Date) -> ClosedRange<Date> {
        let start = (model.earliest ?? now.addingTimeInterval(-90 * 86_400)).addingTimeInterval(-7 * 86_400)
        return min(start, now.addingTimeInterval(-86_400))...now.addingTimeInterval(3 * 86_400)
    }

    private func initialDomain(_ full: ClosedRange<Date>, now: Date) -> ClosedRange<Date> {
        guard let days = config.period else { return full }
        let span = Double(days) * 86_400
        return max(full.lowerBound, now.addingTimeInterval(-span))...now.addingTimeInterval(span * 0.04)
    }

    private func clamp(_ range: ClosedRange<Date>, shift: TimeInterval, full: ClosedRange<Date>) -> ClosedRange<Date> {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        var lower = range.lowerBound.addingTimeInterval(shift)
        lower = min(max(lower, full.lowerBound), full.upperBound.addingTimeInterval(-span))
        return lower...lower.addingTimeInterval(span)
    }

    private func zoom(_ range: ClosedRange<Date>, by factor: CGFloat, around anchor: Date, full: ClosedRange<Date>) -> ClosedRange<Date> {
        let span = range.upperBound.timeIntervalSince(range.lowerBound)
        let fullSpan = full.upperBound.timeIntervalSince(full.lowerBound)
        let newSpan = min(fullSpan, max(86_400, span / Double(max(0.05, factor))))
        let ratio = anchor.timeIntervalSince(range.lowerBound) / span
        let lower = anchor.addingTimeInterval(-ratio * newSpan)
        return clamp(lower...lower.addingTimeInterval(newSpan), shift: 0, full: full)
    }

    /// Fits the view to what the search found.
    private func revealMatches(_ model: TimelineModel) {
        let hits = model.releases.filter { $0.matches(query) }
        guard let first = hits.map(\.start).min(), let last = hits.map(\.end).max() else { return }
        let pad = max(last.timeIntervalSince(first) * 0.15, 7 * 86_400)
        withAnimation(.snappy) { domain = first.addingTimeInterval(-pad)...last.addingTimeInterval(pad) }
    }
}

struct ReleaseSelection: Identifiable, Hashable {
    var id: String { release }
    let repository: String
    var release: String
}

// MARK: - Samples

/// Gallery data: two trains splitting off a shared one, with a hotfix and a few events.
enum ReleaseSamples {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)

    static var timeline: RepositoryTimeline {
        var tags: [TagInfo] = []
        for week in 0..<8 {
            let day = now.addingTimeInterval(Double(week - 9) * 7 * 86_400)
            tags.append(TagInfo(name: "release-2026W\(20 + week)-02-eu.01", date: day, commit: "e\(week)", subject: "LAF-\(100 + week): change"))
            tags.append(TagInfo(name: "release-2026W\(20 + week)-03-us.01", date: day.addingTimeInterval(86_400), commit: "u\(week)", subject: "PPT-\(200 + week): change"))
            if week % 3 == 1 {
                tags.append(TagInfo(name: "release-2026W\(20 + week)-02-eu.02", date: day.addingTimeInterval(2 * 86_400), commit: "e\(week)b", subject: "fix"))
            }
        }
        for week in 0..<4 {
            tags.append(TagInfo(name: "release-2026W\(14 + week)-02.01", date: now.addingTimeInterval(Double(week - 14) * 7 * 86_400), commit: "s\(week)", subject: "change"))
        }
        let repository = RepositoryConfig(id: "sample", name: "api", path: "/tmp")
        return ReleaseGrouping.timeline(tags, repository: repository, onBase: Set(tags.map(\.name)).subtracting(["release-2026W24-02-eu.02"]), now: now)
    }

    static var events: [ReleaseEvent] {
        [ReleaseEvent(date: now.addingTimeInterval(-40 * 86_400), kind: .launch, title: "Web launch"),
         ReleaseEvent(date: now.addingTimeInterval(-22 * 86_400), kind: .incident, title: "Pods crash-loop"),
         ReleaseEvent(date: now.addingTimeInterval(-60 * 86_400), kind: .milestone, title: "Train split")]
    }
}
