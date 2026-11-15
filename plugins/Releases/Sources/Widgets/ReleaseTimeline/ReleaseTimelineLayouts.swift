import DashKit
import DashKitUI
import SwiftUI

// The Release Timeline's layouts besides the chart, one per size family. They take plain values
// (releases, what's live), so the gallery draws them from the sample timeline.

extension Release {
    /// Live, hotfixed, or done.
    var tone: Tone { isHotfix ? .warning : isCurrent ? .success : .neutral }

    /// "3 builds · 14 commits · 6 tickets".
    var shippedLine: String {
        var parts = ["\(builds.count) build\(builds.count == 1 ? "" : "s")", "\(newCommits.count) commit\(newCommits.count == 1 ? "" : "s")"]
        if !tickets.isEmpty { parts.append("\(tickets.count) ticket\(tickets.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

enum ReleaseGlanceText {
    /// The narrow layout's headline: the newest live release and how long ago its build was cut.
    static func headline(_ live: [ReleaseTimelineView.Live], now: Date) -> (title: String, detail: String) {
        guard let newest = live.max(by: { $0.since < $1.since }) else { return ("Nothing live", "No release tag yet") }
        let ago = RelativeDateTimeFormatter().localizedString(for: newest.since, relativeTo: now)
        return ("\(newest.name) live", "Cut \(ago) · \(live.count) train\(live.count == 1 ? "" : "s") live")
    }
}

// MARK: Narrow

/// What's live on each train, or what the search found.
struct ReleaseGlance: View {
    let live: [ReleaseTimelineView.Live]
    /// The search's matches, newest first; nil when not searching.
    let matches: [Release]?
    /// The newest releases, to fill up to three rows when fewer trains are live.
    let latest: [Release]
    let now: Date
    let selectedID: String?
    let trainTitle: (Release) -> String
    let open: (Release) -> Void

    var body: some View {
        let headline = ReleaseGlanceText.headline(live, now: now)
        VStack(alignment: .leading, spacing: 8) {
            if let matches {
                if matches.isEmpty { Text("No release matches").font(.callout).foregroundStyle(.secondary) }
                ForEach(matches) { release in row(release, subtitle: "\(trainTitle(release)) · \(release.start.formatted(.dateTime.day().month(.abbreviated)))") }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(headline.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Divider()
                ForEach(live.prefix(3)) { live in
                    ItemRow(live.name, subtitle: "\(live.train) · \(live.release.shippedLine)", monospacedTitle: true) {
                        StatusDot(live.hotfix ? .warning : .success, help: live.hotfix ? "Hotfix live" : "Live")
                    } trailing: {
                        Text(RelativeDateTimeFormatter().localizedString(for: live.since, relativeTo: now))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .releaseRow(selectedID == live.release.id) { open(live.release) }
                }
                // Up to three rows: what's live, then the newest releases before it.
                let liveIDs = Set(live.map(\.release.id))
                ForEach(latest.filter { !liveIDs.contains($0.id) }.prefix(max(0, 3 - live.count))) { release in
                    row(release, subtitle: "\(trainTitle(release)) · \(release.start.formatted(.dateTime.day().month(.abbreviated)))")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ release: Release, subtitle: String) -> some View {
        ItemRow(release.shortName, subtitle: subtitle, monospacedTitle: true) {
            StatusDot(release.tone)
        }
        .releaseRow(selectedID == release.id) { open(release) }
    }
}

// MARK: Wide

/// Beside the chart: what's live on each train, then the newest releases with what they shipped.
struct ReleaseContextColumn: View {
    let live: [ReleaseTimelineView.Live]
    let latest: [Release]
    let now: Date
    let selectedID: String?
    let trainTitle: (Release) -> String
    let open: (Release) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !live.isEmpty {
                    sectionTitle("Live now")
                    ForEach(live) { live in
                        HStack(spacing: 6) {
                            Badge(live.train, tone: live.hotfix ? .warning : .info)
                            Text(live.name).font(.callout.monospaced()).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(RelativeDateTimeFormatter().localizedString(for: live.since, relativeTo: now)).font(.caption).foregroundStyle(.secondary)
                        }
                        .releaseRow(selectedID == live.release.id) { open(live.release) }
                    }
                }
                sectionTitle("Latest releases")
                ForEach(latest) { release in
                    ItemRow(release.shortName, subtitle: "\(trainTitle(release)) · \(release.start.formatted(.dateTime.day().month(.abbreviated))) · \(release.shippedLine)",
                            monospacedTitle: true) {
                        StatusDot(release.tone, help: release.isHotfix ? "Hotfix" : release.isCurrent ? "Live" : "Replaced")
                    }
                    .releaseRow(selectedID == release.id) { open(release) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }
}

// MARK: Large

/// Every release as a row: name, train, when, how long it was live and what it shipped. Clicking
/// picks one (the chart and the detail follow); double-clicking opens it.
struct ReleaseTable: View {
    let releases: [Release]
    let now: Date
    let trainTitle: (Release) -> String
    @Binding var selectedID: String?
    let open: (Release) -> Void

    var body: some View {
        Table(releases, selection: $selectedID) {
            TableColumn("Release") { release in
                HStack(spacing: 6) {
                    StatusDot(release.tone)
                    Text(release.shortName).font(.callout.monospaced())
                }
            }
            TableColumn("Train") { release in Text(trainTitle(release)) }
                .width(min: 44, ideal: 64)
            TableColumn("Started") { release in Text(release.start.formatted(.dateTime.day().month(.abbreviated))).foregroundStyle(.secondary) }
            TableColumn("Live for") { release in
                Text(release.isCurrent ? "live" : Duration.seconds(release.end.timeIntervalSince(release.start)).formatted(.units(allowed: [.days, .hours], width: .narrow, maximumUnitCount: 1)))
                    .foregroundStyle(release.isCurrent ? Tone.success.color : .secondary)
            }
            TableColumn("Builds") { release in Text("\(release.builds.count)").monospacedDigit() }
                .width(min: 44, ideal: 56)
            TableColumn("Commits") { release in Text("\(release.newCommits.count)").monospacedDigit() }
                .width(min: 44, ideal: 56)
            TableColumn("Tickets") { release in Text("\(release.tickets.count)").monospacedDigit() }
                .width(min: 44, ideal: 56)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let release = releases.first(where: { $0.id == id }) { open(release) }
        }
    }
}

/// One release at a glance: dates, builds, tickets and authors, with a button to open it.
struct ReleaseDetailPanel: View {
    let release: Release?
    let now: Date
    let trainTitle: (Release) -> String
    let open: (Release) -> Void

    var body: some View {
        if let release {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(release.shortName).font(.headline.monospaced()).lineLimit(1)
                        Badge(trainTitle(release), tone: .info)
                        if release.isCurrent { Badge("live", tone: .success) }
                        if release.isHotfix { Badge("hotfix", tone: .warning) }
                        Spacer(minLength: 0)
                        Button("Open", systemImage: "arrow.up.forward.square") { open(release) }
                            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Builds, commits and tickets")
                    }
                    Text(dates(release)).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        count(release.builds.count, "builds")
                        count(release.newCommits.count, "commits")
                        count(release.tickets.count, "tickets")
                    }
                    if !release.tickets.isEmpty {
                        FlowLayout(spacing: 4) {
                            ForEach(release.tickets.prefix(12), id: \.self) { Badge($0, tone: .accent) }
                        }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(release.builds.reversed()) { build in
                            HStack(spacing: 6) {
                                StatusDot(build.onBase ? .neutral : .warning, help: build.onBase ? "On the base branch" : "Hotfix")
                                Text(build.tag).font(.caption.monospaced()).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(build.date.formatted(.dateTime.day().month(.abbreviated))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !release.authors.isEmpty {
                        Label(release.authors.joined(separator: ", "), systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        } else {
            StateView(.empty(title: "No release", systemImage: "tag"))
        }
    }

    private func dates(_ release: Release) -> String {
        let start = release.start.formatted(.dateTime.day().month(.abbreviated))
        let end = release.isCurrent ? "today" : release.end.formatted(.dateTime.day().month(.abbreviated))
        let days = Int((min(release.end, now).timeIntervalSince(release.start) / 86_400).rounded())
        return "\(start) → \(end) · \(days) day\(days == 1 ? "" : "s")"
    }

    private func count(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.title3.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension View {
    /// A tappable row with the selection's tint behind it.
    func releaseRow(_ selected: Bool, action: @escaping () -> Void) -> some View {
        padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
            .onTapGesture(perform: action)
    }
}
