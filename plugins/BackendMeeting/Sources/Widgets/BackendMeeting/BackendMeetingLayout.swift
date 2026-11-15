import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// A stored report as the widget shows it; decoupled from SwiftData so previews can use samples.
struct ReportDigest: Identifiable, Equatable, Sendable {
    let id: UUID
    let start: Date
    let end: Date
    let markdown: String
    let createdAt: Date
    /// The markdown file on disk, when the feature writes one and it's still there.
    var file: URL?

    init(id: UUID = UUID(), start: Date, end: Date, markdown: String, createdAt: Date, file: URL? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.markdown = markdown
        self.createdAt = createdAt
        self.file = file
    }

    init(_ report: BackendReport, file: URL?) {
        self.init(id: report.id, start: report.start, end: report.end, markdown: report.markdown, createdAt: report.createdAt, file: file)
    }

    var rangeLabel: String { ReportRange(start: start, end: end).label }
    var sections: [ReportSection] { ReportSection.sections(markdown) }
}

/// What the widget's buttons do; no-ops in the gallery.
struct BackendMeetingCommands {
    /// Writes the report for a range (cycle weeks, 0 for "since the last report") and returns its id.
    var generate: (ReportRange, Int) async throws -> UUID? = { _, _ in nil }
    var delete: (UUID) -> Void = { _ in }
}

/// The Backend Meeting widget at any size: one layout per size family, live or from samples.
///
/// - narrow: the period, whether the report is ready, its themes, and Generate.
/// - medium: the toolbar (range, history, copy, reveal, generate) over the report.
/// - wide: the toolbar over the report's themes in columns.
/// - large: a panel with the next range, cycle and past reports beside the chosen report's themes.
struct BackendMeetingLayout: View {
    let reports: [ReportDigest]
    var progress: String?
    @Binding var config: BackendMeetingWidget.Config
    var commands = BackendMeetingCommands()
    @Environment(\.widgetLayout) private var layout
    @State private var shownID: UUID?
    @State private var error: String?
    @State private var copied = false

    private var shown: ReportDigest? { reports.first { $0.id == shownID } ?? reports.first }
    private var next: ReportRange {
        ReportRange.make(cycleWeeks: config.cycleWeeks, sinceLastReport: config.sinceLastReport, lastEnd: reports.first?.end)
    }

    var body: some View {
        switch layout.family {
        case .narrow:
            glance
        case .wide:
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                status
                if let shown {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            reportTitle(shown)
                            ReportColumns(sections: shown.sections, minWidth: 200)
                        }
                    }
                } else if progress == nil {
                    empty
                }
            }
        case .large:
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                status
                HStack(alignment: .top, spacing: 12) {
                    sidePanel.frame(width: 220)
                    Divider()
                    if let shown {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                reportTitle(shown)
                                ReportColumns(sections: shown.sections, minWidth: 220)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    } else if progress == nil {
                        empty
                    }
                }
            }
        default:
            VStack(alignment: .leading, spacing: 10) {
                toolbar
                status
                if let shown {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            reportTitle(shown)
                            ReportMarkdown(markdown: shown.markdown)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if progress == nil {
                    empty
                }
            }
        }
    }

    // MARK: Narrow

    private var glance: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    StatusDot(progress != nil ? .info : reports.isEmpty ? .warning : .success)
                    Text(progress != nil ? "Writing…" : reports.isEmpty ? "No report yet" : "Report ready").font(.headline).lineLimit(1)
                }
                Text(reports.first?.rangeLabel ?? "Next: \(next.label)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let progress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else if let latest = reports.first {
                // The themes that fit, one line each.
                let fit = max(1, Int((layout.size.height - 90) / 22))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(latest.sections.prefix(fit).enumerated()), id: \.offset) { _, section in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(.tint).frame(width: 5, height: 5).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                            Text(section.title).font(.callout).lineLimit(1)
                        }
                    }
                    if latest.sections.count > fit {
                        Text("\(latest.sections.count - fit) more").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
            HStack(spacing: 6) {
                generateButton
                if let latest = reports.first { copyButton(latest).buttonStyle(.borderless) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Shared parts

    private var toolbar: some View {
        HStack(spacing: 8) {
            rangeMenu
            Spacer()
            if !reports.isEmpty, layout.family != .large { history }
            if let shown {
                copyButton(shown)
                if let url = shown.file {
                    Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .labelStyle(.iconOnly)
                        .help(url.path)
                }
            }
            generateButton
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var status: some View {
        if let progress {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(progress).font(.callout).foregroundStyle(.secondary)
            }
        }
        if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
    }

    private var empty: some View {
        StateView(.empty(title: "No report yet", systemImage: "person.2.wave.2",
                         message: "Generate one for \(next.label) from your PRs, tickets and activity."))
    }

    private func reportTitle(_ report: ReportDigest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(report.rangeLabel).font(.headline)
            if report.id != reports.first?.id { Badge("past report") }
        }
    }

    private var rangeMenu: some View {
        Menu {
            Picker("Cycle", selection: $config.cycleWeeks) {
                ForEach(1...10, id: \.self) { Text($0 == 1 ? "1 week" : "\($0) weeks").tag($0) }
            }
            Toggle("Start where the last report ended", isOn: $config.sinceLastReport)
        } label: {
            Label(next.label, systemImage: "calendar")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("The next report covers \(next.label). Change the cycle here.")
    }

    private var history: some View {
        Menu {
            ForEach(reports) { report in
                Button { shownID = report.id } label: {
                    if report.id == shown?.id { Label(report.rangeLabel, systemImage: "checkmark") } else { Text(report.rangeLabel) }
                }
            }
            if let shown {
                Divider()
                Button("Delete This Report", role: .destructive) { delete(shown) }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Past reports")
    }

    /// Large: the next report, the cycle and the past reports to pick from.
    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Next report").font(.caption.bold()).foregroundStyle(.secondary)
                Text(next.label).font(.callout)
                Text(config.sinceLastReport ? "Starts where the last one ended" : "Last \(config.cycleWeeks) week\(config.cycleWeeks == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let latest = reports.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last written").font(.caption.bold()).foregroundStyle(.secondary)
                    Text(latest.createdAt.formatted(.relative(presentation: .named))).font(.callout)
                    Text("\(latest.sections.count) themes").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !reports.isEmpty {
                Text("Reports · \(reports.count)").font(.caption.bold()).foregroundStyle(.secondary)
                List(reports) { report in
                    ItemRow(report.rangeLabel, subtitle: "\(report.sections.count) themes") {
                        StatusDot(report.id == reports.first?.id ? .success : .neutral)
                    }
                    .onTapGesture { shownID = report.id }
                    .listRowBackground(report.id == shown?.id ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contextMenu {
                        Button("Delete This Report", role: .destructive) { delete(report) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    private var generateButton: some View {
        Button {
            error = nil
            let range = next
            let weeks = config.sinceLastReport ? 0 : config.cycleWeeks
            Task {
                do {
                    if let id = try await commands.generate(range, weeks) { shownID = id }
                } catch {
                    self.error = error.localizedDescription
                }
            }
        } label: {
            Label(reports.isEmpty ? "Generate" : "New Report", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(progress != nil)
        .help("Read your PRs, tickets and activity for \(next.label) and write the highlights")
    }

    private func copyButton(_ report: ReportDigest) -> some View {
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(report) }
            .labelStyle(.iconOnly)
            .help("Copy the report as markdown")
    }

    private func delete(_ report: ReportDigest) {
        commands.delete(report.id)
        shownID = nil
    }

    private func copy(_ report: ReportDigest) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.markdown, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// The report's themes as cards in as many columns as fit.
struct ReportColumns: View {
    let sections: [ReportSection]
    let minWidth: CGFloat

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title).font(.callout.bold())
                    if !section.summary.isEmpty {
                        Text(Self.inline(section.summary)).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(.secondary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                            Text(Self.inline(item)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if section.summary.isEmpty && section.items.isEmpty {
                        Text("Nothing this cycle").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
        }
        .textSelection(.enabled)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

extension ReportDigest {
    /// The gallery's sample reports, newest first: no network, no accounts.
    static var samples: [ReportDigest] {
        let day: TimeInterval = 24 * 3600
        return [
            ReportDigest(start: .now.addingTimeInterval(-14 * day), end: .now.addingTimeInterval(-day), markdown: """
                - **Social connection**: reworked the Apple sign-in flow to link accounts from the email scope
                - **Catalog sync**: automatic user creation during social sign-up and sync of the region flag
                - **Renewals**: renewal endpoint shipped with proration on upgrade
                - **In chantier**:
                  - observability on tag operations and service calls (in review)
                  - recordings cap removal on mobile (open PR)
                - **Debug & Fix**:
                  - flaky renewal test stabilised
                  - QA workspace OOM on boot
                """, createdAt: .now.addingTimeInterval(-day + 3600)),
            ReportDigest(start: .now.addingTimeInterval(-28 * day), end: .now.addingTimeInterval(-14 * day), markdown: """
                - **Checkout**: plan price shown on checkout for every market
                - **In chantier**:
                  - channel lineup cache per market
                - **Debug & Fix**
                """, createdAt: .now.addingTimeInterval(-14 * day)),
            ReportDigest(start: .now.addingTimeInterval(-42 * day), end: .now.addingTimeInterval(-28 * day), markdown: """
                - **Auth**: legacy auth header dropped from the gateway
                - **Debug & Fix**:
                  - 502s on checkout from the connection pool limit
                """, createdAt: .now.addingTimeInterval(-28 * day)),
        ]
    }
}
