import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// The widget body, one layout per size family: what's live when narrow, the chart with zoom,
/// pan, search and selection when medium, the chart with the latest releases beside it when wide,
/// and the chart over a release table and the picked release's detail when large.
struct ReleaseTimelineView: View {
    let feature: ReleasesFeature
    /// nil in the gallery: no repository picker.
    let host: (any ExtensionContext)?
    @Binding var config: ReleaseTimelineWidget.Config
    /// The widget's DashQL query (its query bar): only the releases it matches stay on the chart.
    var widgetQuery: WidgetQuery?
    var queryText = ""
    @State private var queryIDs: [String]?

    @State var domain: ClosedRange<Date>?
    @State private var dragStart: ClosedRange<Date>?
    @State private var zoomStart: ClosedRange<Date>?
    @State private var hovered: Release?
    @State private var hoveredEvent: ReleaseEvent?
    /// The release whose detail sheet is open.
    @State var selection: ReleaseSelection?
    /// The release the user picked: highlighted and published for linked widgets until another
    /// is picked or it's clicked again.
    @State var picked: ReleaseSelection?
    /// What Dashii's actions changed for now (train, period); the saved settings stay, and this
    /// resets when they change.
    @State var override: ReleaseTimelineWidget.Config?
    @State private var eventSelection: ReleaseEvent?
    @State var searching = false
    @State var query = ""
    /// A date the search jumped to: marked on the chart, its live release highlighted.
    @State var focusDate: Date?
    /// The widget's size and family from the dashboard (or the gallery's preset).
    @Environment(\.widgetLayout) private var widgetLayout

    /// The settings with Dashii's temporary changes on top: what the timeline shows.
    var shown: ReleaseTimelineWidget.Config { override ?? config }

    var repositories: [RepositoryConfig] {
        feature.repositories.filter { shown.repository == nil || $0.id == shown.repository }
    }

    var timelines: [RepositoryTimeline] { repositories.compactMap { feature.timelines[$0.id] } }

    var body: some View {
        main
            .handlesWidgetActions { name, input in try perform(name, input) }
            .onChange(of: config) { override = nil }
            .onExitCommand { picked = nil }
            .reportsSelection(pickedRow)
            .reportsWidgetState(uiState)
            .task(id: QueryRows.key(queryText, allReleases, row: queryRow)) {
                queryIDs = await QueryRows.ids(widgetQuery, allReleases, row: queryRow)
            }
    }

    @ViewBuilder private var main: some View {
        if feature.repositories.isEmpty || repositories.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: ReleaseTimelineWidget.systemImage).font(.largeTitle).foregroundStyle(.tertiary)
                Text(feature.repositories.isEmpty ? "Choose a repository" : "This widget's repository was removed").font(.headline)
                Text("Pick one your GitHub or GitLab integration watches, or a local checkout.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let host {
                    RepositoryPicker(feature: feature, host: host, selection: $config.repository)
                        .labelsHidden()
                        .fixedSize()
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    var currentModel: TimelineModel {
        let model = TimelineModel(timelines: timelines, events: shown.events ? feature.events(for: shown.repository) : [],
                                  train: shown.train, showEvents: shown.events)
        return queryIDs.map { model.keeping(Set($0)) } ?? model
    }

    /// Every release the widget's repositories and train show, before its query.
    private var allReleases: [Release] {
        timelines.flatMap { timeline in timeline.releases.filter { shown.train == nil || $0.train == shown.train } }
    }

    private func queryRow(_ release: Release) -> JSONValue {
        release.queryRow(repository: timelines.first { $0.releases.contains(release) }?.repository.name ?? release.repository)
    }

    private var content: some View {
        let model = currentModel
        let now = feature.now()
        let full = fullDomain(model, now: now)
        let visible = domain ?? initialDomain(full, now: now)
        let size = widgetLayout.size
        return Group {
            switch widgetLayout.family {
            case .narrow:
                VStack(alignment: .leading, spacing: 8) {
                    if searching { header(model, now: now, showLive: false) }
                    ReleaseGlance(live: liveNow(now), matches: searching && !query.isEmpty ? Array(model.releases.filter { $0.matches(query) }.suffix(3).reversed()) : nil,
                                  latest: latest(model, count: 6), now: now, selectedID: picked?.release, trainTitle: trainTitle, open: click)
                }
            case .wide:
                HStack(alignment: .top, spacing: 12) {
                    timeline(model, full: full, visible: visible, now: now, showLive: false)
                    Divider()
                    ReleaseContextColumn(live: liveNow(now), latest: latest(model, count: 8), now: now, selectedID: picked?.release,
                                         trainTitle: trainTitle, open: click)
                        .frame(width: size.width * 0.3)
                }
            case .large:
                VStack(alignment: .leading, spacing: 10) {
                    timeline(model, full: full, visible: visible, now: now, showLive: true)
                        .frame(maxHeight: size.height * 0.5)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: 12) {
                        ReleaseTable(releases: model.releases.sorted { $0.start > $1.start }, now: now, trainTitle: trainTitle,
                                     selectedID: Binding(get: { picked?.release }, set: { id in
                                         picked = id.flatMap { id in model.releases.first { $0.id == id } }.map { ReleaseSelection(repository: $0.repository, release: $0.id) }
                                     }),
                                     open: { selection = ReleaseSelection(repository: $0.repository, release: $0.id) })
                        Divider()
                        ReleaseDetailPanel(release: detailRelease(model, now: now), now: now, trainTitle: trainTitle,
                                           open: { selection = ReleaseSelection(repository: $0.repository, release: $0.id) })
                            .frame(width: size.width * 0.34)
                    }
                }
            default:
                timeline(model, full: full, visible: visible, now: now, showLive: true)
            }
        }
        .widgetHeader { headerControls(zoomed: domain != nil) }
        .sheet(item: $selection) { selection in
            ReleaseDetailSheet(feature: feature, repository: selection.repository, releaseID: selection.release)
        }
        .sheet(item: $eventSelection) { event in
            ReleaseEventSheet(event: event, releases: timelines.map { timeline in (timeline, timeline.liveAt(event.date)) })
        }
        .onChange(of: config) { domain = nil }
    }

    /// The chart with its title row and footer: the medium layout, and the top of the wider ones.
    private func timeline(_ model: TimelineModel, full: ClosedRange<Date>, visible: ClosedRange<Date>, now: Date, showLive: Bool) -> some View {
        let lanesHeight = TimelineLayout(size: .zero, domain: visible, compact: false, lanes: model.lanes).height
        return VStack(alignment: .leading, spacing: 6) {
            header(model, now: now, showLive: showLive)
            if model.lanes.isEmpty {
                StateView(.empty(title: "No release tags", systemImage: "tag",
                                 message: "No tags match \(repositories.map(\.tagPattern).joined(separator: ", ")). Check the tag pattern in Settings › Releases."))
            } else {
                GeometryReader { geometry in
                    let layout = TimelineLayout(size: CGSize(width: geometry.size.width, height: 0), domain: visible, compact: false, lanes: model.lanes)
                    ScrollView(.vertical) {
                        chart(model, layout: layout, full: full, now: now, compact: false)
                            .frame(height: layout.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                // No taller than the lanes: the footer stays under them, and wider layouts get the rest.
                .frame(idealHeight: lanesHeight, maxHeight: lanesHeight)
                footer(model, now: now)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Clicking a release selects and opens it; clicking the selected one again unselects it.
    private func click(_ release: Release) {
        let clicked = ReleaseSelection(repository: release.repository, release: release.id)
        if picked?.release == release.id && picked?.repository == release.repository {
            picked = nil
        } else {
            picked = clicked
            selection = clicked
        }
    }

    /// The newest releases first.
    private func latest(_ model: TimelineModel, count: Int) -> [Release] {
        Array(model.releases.sorted { $0.start > $1.start }.prefix(count))
    }

    /// The large layout's detail: the picked release, else the hovered one, else the newest live.
    private func detailRelease(_ model: TimelineModel, now: Date) -> Release? {
        if let picked, let release = model.releases.first(where: { $0.id == picked.release }) { return release }
        return hovered ?? liveNow(now).map(\.release).max { $0.start < $1.start } ?? model.releases.last
    }

    /// "EU", "Shared" (with the repository's name when several are shown).
    func trainTitle(_ release: Release) -> String {
        guard let timeline = timelines.first(where: { $0.repository.id == release.repository }) else { return release.train.uppercased() }
        return (timelines.count > 1 ? timeline.repository.name + " " : "") + timeline.trainTitle(release.train)
    }

    private func chart(_ model: TimelineModel, layout: TimelineLayout, full: ClosedRange<Date>, now: Date, compact: Bool) -> some View {
        let shown = layout.domain
        let dateQuery = searching ? ReleaseDates.search(query, now: now) : nil
        return TimelineChart(model: model, domain: shown, now: now, compact: compact, selected: picked?.release ?? selection?.release,
                             hovered: hovered?.id ?? focused(model)?.id, query: searching && dateQuery == nil ? query : "",
                             marker: searching ? focusDate : nil)
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
            // Mouse wheel and trackpad scrolling: up and down zoom around the pointer, sideways (or
            // with Shift) pans. Hold Option to scroll the lanes instead.
            .modifier(ScrollWheelZoom { delta, horizontal, point in
                let current = domain ?? shown
                if horizontal != 0 {
                    let perPoint = current.upperBound.timeIntervalSince(current.lowerBound) / Double(layout.plot.upperBound - layout.plot.lowerBound)
                    domain = clamp(current, shift: -Double(horizontal) * perPoint, full: full)
                } else if delta != 0 {
                    let anchor = TimelineLayout(size: layout.size, domain: current, compact: compact, lanes: model.lanes).date(point.x)
                    domain = zoom(current, by: CGFloat(exp(Double(delta) * 0.02)), around: anchor, full: full)
                }
            })
            .onTapGesture { point in
                if let release = layout.release(at: point) {
                    click(release)
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

    /// The title row: count, repository and what's live, or the search field while searching.
    private func header(_ model: TimelineModel, now: Date, showLive: Bool) -> some View {
        HStack(spacing: 6) {
            QueryCount(shown: model.releases.count, total: allReleases.count, query: queryText)
            if searching {
                TextField("Ticket, text or date (12 Oct, 2026-10-12, W41)", text: $query)
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit { revealMatches(model, now: now) }
                    .onChange(of: query) { focusDate = nil }
                if let date = ReleaseDates.search(query, now: now) {
                    Text(date.formatted(.dateTime.day().month(.abbreviated).year())).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("Press Return to jump to this date")
                } else if !query.isEmpty {
                    let hits = model.releases.filter { $0.matches(query) }.count
                    Text("\(hits)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).help("\(hits) releases match")
                }
            } else {
                Text(title(model)).font(.caption.bold()).lineLimit(1)
                if showLive {
                    ForEach(liveNow(now), id: \.id) { live in
                        Badge("\(live.train) \(live.name)", tone: live.hotfix ? .warning : .info, systemImage: "dot.radiowaves.left.and.right")
                            .help("Live now on \(live.train): \(live.tag)")
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    /// Loading, errors, back-to-period and search: in the card's header.
    private func headerControls(zoomed: Bool) -> some View {
        HStack(spacing: 6) {
            if repositories.contains(where: { feature.loading.contains($0.id) }) { ProgressView().controlSize(.mini) }
            if let error = repositories.lazy.compactMap({ feature.errors[$0.id] }).first {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning.color).help(error)
            }
            if zoomed {
                Button { withAnimation(.snappy) { domain = nil } } label: { Image(systemName: "arrow.uturn.backward") }
                    .buttonStyle(.borderless).help("Back to the widget's period")
            }
            Button { searching.toggle(); if !searching { query = ""; focusDate = nil } } label: { Image(systemName: searching ? "xmark.circle.fill" : "magnifyingglass") }
                .buttonStyle(.borderless).help(searching ? "Stop searching" : "Search releases by ticket, text or date")
        }
    }

    private func footer(_ model: TimelineModel, now: Date) -> some View {
        Group {
            if let hovered = hovered ?? focused(model) {
                Text((hovered.id == focused(model)?.id && self.hovered == nil ? "Live on \(focusDate?.formatted(.dateTime.day().month(.abbreviated)) ?? ""): " : "")
                     + hoverLine(hovered, now: now)).lineLimit(1).truncationMode(.tail)
            } else if let hoveredEvent {
                Text("\(hoveredEvent.kind.title) · \(hoveredEvent.date.formatted(date: .abbreviated, time: .omitted)) · \(hoveredEvent.title)").lineLimit(1)
            } else {
                Text("Scroll or pinch to zoom, drag to pan, click a release for details.").foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func title(_ model: TimelineModel) -> String {
        let count = model.releases.count
        return (repositories.count == 1 ? repositories[0].name + " · " : "") + "\(count) release\(count == 1 ? "" : "s")"
    }

    struct Live: Identifiable {
        let id: String
        let train: String
        let name: String
        let tag: String
        let hotfix: Bool
        let release: Release
        /// When the live build was tagged.
        let since: Date
    }

    func liveNow(_ now: Date) -> [Live] {
        timelines.flatMap { timeline in
            timeline.liveAt(now).filter { shown.train == nil || $0.train == shown.train }.map { live in
                Live(id: timeline.repository.id + live.train, train: (timelines.count > 1 ? timeline.repository.name + " " : "") + timeline.trainTitle(live.train),
                     name: live.release.shortName, tag: live.build.tag, hotfix: !live.build.onBase, release: live.release, since: live.build.date)
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

    func fullDomain(_ model: TimelineModel, now: Date) -> ClosedRange<Date> {
        let start = (model.earliest ?? now.addingTimeInterval(-90 * 86_400)).addingTimeInterval(-7 * 86_400)
        return min(start, now.addingTimeInterval(-86_400))...now.addingTimeInterval(3 * 86_400)
    }

    func initialDomain(_ full: ClosedRange<Date>, now: Date) -> ClosedRange<Date> {
        guard let days = shown.period else { return full }
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

    /// The release live at the date the search jumped to (the first lane's, then any).
    func focused(_ model: TimelineModel) -> Release? {
        guard searching, let focusDate else { return nil }
        return model.releases.first { $0.start <= focusDate && focusDate < $0.end }
    }

    /// Jumps to a searched date (keeping the zoom, at least three weeks wide), else fits the view
    /// to the releases the text matches.
    func revealMatches(_ model: TimelineModel, now: Date) {
        if let date = ReleaseDates.search(query, now: now) {
            let full = fullDomain(model, now: now)
            let current = domain ?? initialDomain(full, now: now)
            let span = max(current.upperBound.timeIntervalSince(current.lowerBound), 21 * 86_400)
            focusDate = date
            withAnimation(.snappy) { domain = clamp(date.addingTimeInterval(-span / 2)...date.addingTimeInterval(span / 2), shift: 0, full: full) }
            return
        }
        let hits = model.releases.filter { $0.matches(query) }
        guard let first = hits.map(\.start).min(), let last = hits.map(\.end).max() else { return }
        let pad = max(last.timeIntervalSince(first) * 0.15, 7 * 86_400)
        withAnimation(.snappy) { domain = first.addingTimeInterval(-pad)...last.addingTimeInterval(pad) }
    }
}

/// Scroll-wheel zoom for the timeline: while the pointer is over the view, wheel and trackpad
/// scrolling go to `action` (vertical delta, horizontal delta, pointer in the view) instead of
/// scrolling the page. Option lets the scroll through.
private struct ScrollWheelZoom: ViewModifier {
    let action: (_ vertical: CGFloat, _ horizontal: CGFloat, _ point: CGPoint) -> Void
    @State private var pointer: CGPoint?
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): pointer = point
                case .ended: pointer = nil
                }
            }
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                    guard !event.modifierFlags.contains(.option) else { return event }
                    let shift = event.modifierFlags.contains(.shift)
                    // Lines (mouse wheels) are much coarser than trackpad points.
                    let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
                    let vertical = shift ? 0 : event.scrollingDeltaY * scale
                    let horizontal = (shift ? event.scrollingDeltaY : event.scrollingDeltaX) * scale
                    let handled = MainActor.assumeIsolated { () -> Bool in
                        guard let point = pointer else { return false }
                        if abs(horizontal) > abs(vertical) { action(0, horizontal, point) } else { action(vertical, 0, point) }
                        return true
                    }
                    return handled ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}
