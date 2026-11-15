import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// One release in depth: builds, dates, live period, the commits it brought, tickets, and what
/// each train had live on a chosen day. Previous/Next step along the train.
struct ReleaseDetailSheet: View {
    let feature: ReleasesFeature
    let repository: String
    @State var releaseID: String
    @State private var filter = ""
    @State private var liveDate = Date.now

    private var timeline: RepositoryTimeline? { feature.timelines[repository] }
    private var release: Release? { timeline?.releases.first { $0.id == releaseID } }

    var body: some View {
        if let timeline, let release {
            content(release, timeline)
                .frame(minWidth: 520, idealWidth: 720, minHeight: 460, idealHeight: 640)
        } else {
            DetailScaffold("Release", content: { StateView(.empty(title: "This release is gone", systemImage: "tag", message: "Its tag was deleted or the repository's settings changed.")) })
                .frame(minWidth: 420, minHeight: 300)
        }
    }

    private func content(_ release: Release, _ timeline: RepositoryTimeline) -> some View {
        let trainReleases = timeline.releases(on: release.train)
        let previous = release.index > 0 ? trainReleases[release.index - 1] : nil
        let next = release.index + 1 < trainReleases.count ? trainReleases[release.index + 1] : nil
        return DetailScaffold(release.name, subtitle: "\(timeline.repository.name) · \(timeline.trainTitle(release.train)) train · release \(release.index + 1) of \(release.trainCount)") {
            if release.isCurrent { Badge("live", tone: .success, systemImage: "dot.radiowaves.left.and.right") }
            if release.isHotfix { Badge("hotfix", tone: .warning, systemImage: "bandage") }
        } content: {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) { facts(release, timeline); liveOn(timeline) }.frame(width: 300)
                    commits(release, timeline)
                }
                .frame(minWidth: 660)
                VStack(alignment: .leading, spacing: 12) {
                    facts(release, timeline)
                    commits(release, timeline)
                    liveOn(timeline)
                }
            }
        } actions: {
            Button { go(previous) } label: { Label("Previous", systemImage: "chevron.left") }
                .disabled(previous == nil).keyboardShortcut(.leftArrow, modifiers: [])
                .help(previous.map { "Previous on this train: \($0.name)" } ?? "First release of this train")
            Button { go(next) } label: { Label("Next", systemImage: "chevron.right") }
                .disabled(next == nil).keyboardShortcut(.rightArrow, modifiers: [])
                .help(next.map { "Next on this train: \($0.name)" } ?? "Latest release of this train")
            Spacer()
            Button("Copy Tag") { copy(release.lastBuild.tag) }
        }
    }

    private func go(_ release: Release?) {
        guard let release else { return }
        releaseID = release.id
        filter = ""
    }

    // MARK: Facts

    private func facts(_ release: Release, _ timeline: RepositoryTimeline) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSection("Release") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    row(release.builds.count > 1 ? "First build" : "Tagged", release.start.formatted(date: .abbreviated, time: .shortened))
                    row("Live for", liveFor(release))
                    GridRow {
                        Text("Previous").foregroundStyle(.secondary)
                        if let previous = release.previous {
                            Button(previous) { go(timeline.releases.first { $0.train == release.train && $0.name == previous }) }
                                .buttonStyle(.link).font(.callout.monospaced())
                        } else {
                            Text("none, first release of this train")
                        }
                    }
                    if let base = release.base, base != release.previous.flatMap({ name in timeline.release(named: name)?.lastBuild.tag }) {
                        row("Compared with", base, mono: true)
                    }
                    row("On \(timeline.baseBranch.isEmpty ? "base branch" : timeline.baseBranch)",
                        release.isHotfix ? (release.builds.count > 1 ? "some builds are on a hotfix branch" : "no, hotfix branch") : "yes")
                    row("Commits", "\(release.newCommits.count) new" + (release.commits.count > release.newCommits.count ? ", \(release.commits.count - release.newCommits.count) already shipped" : "")
                        + (release.authors.isEmpty ? "" : " by \(release.authors.count) author\(release.authors.count == 1 ? "" : "s")"))
                }
                .font(.callout)
            }
            if release.builds.count > 1 {
                DetailSection("Builds") {
                    ForEach(release.builds) { build in
                        ItemRow(build.tag, subtitle: [build.date.formatted(date: .abbreviated, time: .shortened), build.shortCommit,
                                                      "\(release.newCommits.filter { $0.build == build.tag }.count) new commits",
                                                      build.date > release.end ? "tagged after the next release" : nil].compactMap { $0 }.joined(separator: " · "),
                                monospacedTitle: true, leading: { StatusDot(build.onBase ? .success : .warning, help: build.onBase ? "On the base branch" : "Hotfix branch") })
                    }
                }
            }
            if !release.tickets.isEmpty {
                DetailSection("Tickets") {
                    FlowLayout(spacing: 4) {
                        ForEach(release.tickets, id: \.self) { ticket in
                            Button { filter = filter == ticket ? "" : ticket } label: {
                                Badge(ticket, tone: filter == ticket ? .accent : .info)
                            }
                            .buttonStyle(.plain).help("Show only \(ticket)'s commits")
                        }
                    }
                }
            }
        }
    }

    private func liveFor(_ release: Release) -> String {
        let days = String(format: "%.1f days", release.days)
        switch release.endReason {
        case .today: return "current release, \(days) so far"
        case .next: return "\(days), until \(release.next.map(Release.short) ?? "the next release")"
        case .idle: return "\(days), then the train went quiet"
        case .handover: return "\(days), until the train split"
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
        }
    }

    // MARK: Commits

    private func commits(_ release: Release, _ timeline: RepositoryTimeline) -> some View {
        let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = release.commits.filter { query.isEmpty || ($0.subject + " " + $0.sha + " " + $0.author + " " + $0.build).lowercased().contains(query) }
        return DetailSection(release.base == nil ? "Commits" : "Commits since \(Release.short(release.base!))") {
            if release.commits.count > 8 {
                TextField("Filter: text, ticket, author, sha", text: $filter).textFieldStyle(.roundedBorder)
            }
            if release.base == nil {
                Text("The first release of its train: nothing to compare it with.").foregroundStyle(.secondary).font(.callout)
            } else if release.commits.isEmpty {
                Text("No new commits: this release re-tags the previous one.").foregroundStyle(.secondary).font(.callout)
            } else if shown.isEmpty {
                Text("No commit matches “\(filter)”.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(CommitGroups.group(shown), id: \.title) { group in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(group.title).font(.caption.bold()).foregroundStyle(.secondary)
                        Text("\(group.commits.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    ForEach(group.commits) { commit in
                        commitRow(commit, release)
                    }
                }
            }
            if release.commitsTruncated { Text("Only the first 1,000 commits of a build are read.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func commitRow(_ commit: ReleaseCommit, _ release: Release) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(commit.subject).font(.callout).lineLimit(2)
            HStack(spacing: 4) {
                Text(commit.shortSHA).font(.caption.monospaced())
                Text("· \(commit.author) · \(commit.date.formatted(.dateTime.month(.abbreviated).day()))")
                if release.builds.count > 1 { Text("· " + Release.short(commit.build)).font(.caption.monospaced()) }
                if commit.alreadyShipped { Badge("already shipped in \(release.base.map(Release.short) ?? "the previous release")", tone: .neutral) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .opacity(commit.alreadyShipped ? 0.5 : 1)
        .contextMenu {
            Button("Copy SHA") { copy(commit.sha) }
            Button("Copy Subject") { copy(commit.subject) }
        }
    }

    // MARK: Live on a date

    private func liveOn(_ timeline: RepositoryTimeline) -> some View {
        let calendar = Calendar.current
        let moment = calendar.isDateInToday(liveDate) ? feature.now() : (calendar.date(byAdding: DateComponents(day: 1, second: -1), to: calendar.startOfDay(for: liveDate)) ?? liveDate)
        let live = timeline.liveAt(moment)
        return DetailSection("Release live on") {
            DatePicker("Day", selection: $liveDate, in: (timeline.releases.first?.start ?? .distantPast)...Date.now, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field)
            if live.isEmpty {
                Text("No release was live then.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(live, id: \.build.tag) { item in
                HStack(spacing: 6) {
                    Badge(timeline.trainTitle(item.train), tone: .info)
                    Button(item.build.tag) { go(item.release) }.buttonStyle(.link).font(.callout.monospaced())
                    Text("tagged " + item.build.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// An event from the events lane, with the releases live that day.
struct ReleaseEventSheet: View {
    let event: ReleaseEvent
    let releases: [(RepositoryTimeline, [(train: String, build: Build, release: Release)])]

    var body: some View {
        DetailScaffold(event.title, subtitle: "\(event.kind.title) · \(event.date.formatted(date: .complete, time: .omitted))") {
            Badge(event.kind.title, tone: event.kind == .incident ? .danger : event.kind == .launch ? .success : .accent, systemImage: event.kind.systemImage)
        } content: {
            if !event.note.isEmpty { DetailSection("Note") { Text(event.note).textSelection(.enabled) } }
            DetailSection("Releases live that day") {
                if releases.allSatisfy({ $0.1.isEmpty }) { Text("None.").foregroundStyle(.secondary) }
                ForEach(releases, id: \.0.repository.id) { timeline, live in
                    ForEach(live, id: \.build.tag) { item in
                        ItemRow(item.build.tag, subtitle: "\(timeline.repository.name) · \(timeline.trainTitle(item.train)) · tagged \(item.build.date.formatted(date: .abbreviated, time: .shortened)) · \(item.release.newCommits.count) commits",
                                monospacedTitle: true, leading: { StatusDot(item.build.onBase ? .info : .warning) })
                    }
                }
            }
        }
        .frame(minWidth: 440, minHeight: 280)
    }
}

/// Wraps its children onto as many lines as needed (ticket chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            for (index, x) in row.items {
                subviews[index].place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + row.y), proposal: .unspecified)
            }
        }
    }

    private struct Row { var items: [(Int, CGFloat)] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if rows[rows.count - 1].width + size.width > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let x = rows[rows.count - 1].items.isEmpty ? 0 : rows[rows.count - 1].width + spacing
            rows[rows.count - 1].items.append((index, x))
            rows[rows.count - 1].width = x + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
