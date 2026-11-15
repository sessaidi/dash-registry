import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

struct BackendMeetingWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// The cycle in weeks (1–10).
        var cycleWeeks: Int = 2
        /// Start where the previous report ended (else always the last `cycleWeeks` weeks).
        var sinceLastReport: Bool = true
    }

    static let kind = "backend-meeting.report"
    static let displayName = "Backend Meeting"
    static let summary = "Your highlights for the backend meeting: what you shipped and what's in progress since the last report, grouped into themes."
    static let systemImage = "person.2.wave.2"
    static let defaultSize = WidgetSize.large
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 24)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": [
            "cycleWeeks": ["type": "integer", "minimum": 1, "maximum": 10, "description": "Cycle length in weeks."],
            "sinceLastReport": ["type": "boolean", "description": "Start where the previous report ended."],
        ],
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        if let feature = context.host.ext(BackendMeetingFeature.self) {
            BackendMeetingView(feature: feature, config: config)
        } else {
            StateView(.failed(message: "Backend Meeting isn't loaded."))
        }
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        CyclePicker(weeks: config.cycleWeeks)
        Toggle("Start where the last report ended", isOn: config.sinceLastReport)
    }

    /// Sample data for the widget gallery: no network, no accounts.
    static func preview(config: Config) -> some View {
        ReportMarkdown(markdown: """
            - **Social connection**: reworked the Apple sign-in flow to link accounts from the email scope
            - **Catalog sync**: automatic user creation during social sign-up and sync of the region flag
            - **In chantier**:
              - observability on tag operations and service calls (in review)
              - recordings cap removal on mobile (open PR)
            - **Debug & Fix**
            """)
        .padding(4)
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let report = context.host.ext(BackendMeetingFeature.self)?.reports(limit: 1).first else { return ["report": .null] }
        return ["range": .string(report.rangeLabel), "report": .string(report.markdown)]
    }
}

struct CyclePicker: View {
    @Binding var weeks: Int

    var body: some View {
        Picker("Cycle", selection: $weeks) {
            ForEach(1...10, id: \.self) { Text($0 == 1 ? "1 week" : "\($0) weeks").tag($0) }
        }
    }
}

/// The latest (or a chosen past) report, with the range the next one covers and Generate.
private struct BackendMeetingView: View {
    let feature: BackendMeetingFeature
    @Binding var config: BackendMeetingWidget.Config
    @Environment(\.widgetLayout) private var layout
    @Query(sort: \BackendReport.end, order: .reverse) private var reports: [BackendReport]
    @State private var shownID: UUID?
    @State private var error: String?
    @State private var copied = false

    private var shown: BackendReport? { reports.first { $0.id == shownID } ?? reports.first }
    private var next: ReportRange {
        ReportRange.make(cycleWeeks: config.cycleWeeks, sinceLastReport: config.sinceLastReport, lastEnd: reports.first?.end)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if layout.family == .narrow { compact } else { full }
        }
    }

    // Narrow: the last report's first themes, and Generate.
    private var compact: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let report = reports.first {
                Text(report.rangeLabel).font(.caption).foregroundStyle(.secondary)
                ReportMarkdown(markdown: report.markdown, limit: max(2, Int(layout.size.height / 40) - 3))
            } else {
                Text("No report yet").font(.headline)
                Text("Next: \(next.label)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            generateButton
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
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
                Spacer()
                if !reports.isEmpty { history }
                if let shown {
                    Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") { copy(shown) }
                        .labelStyle(.iconOnly)
                        .help("Copy the report as markdown")
                    if let url = feature.fileURL(for: shown), FileManager.default.fileExists(atPath: url.path) {
                        Button("Reveal", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .labelStyle(.iconOnly)
                            .help(url.path)
                    }
                }
                generateButton
            }
            .buttonStyle(.borderless)
            if let progress = feature.progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
            if let shown {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(shown.rangeLabel).font(.headline)
                            if shown.id != reports.first?.id { Text("past report").font(.caption).foregroundStyle(.secondary) }
                        }
                        ReportMarkdown(markdown: shown.markdown)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if feature.progress == nil {
                StateView(.empty(title: "No report yet", systemImage: "person.2.wave.2",
                                 message: "Generate one for \(next.label) from your PRs, tickets and activity."))
            }
        }
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
                Button("Delete This Report", role: .destructive) {
                    feature.delete(shown)
                    shownID = nil
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Past reports")
    }

    private var generateButton: some View {
        Button {
            error = nil
            let range = next
            let weeks = config.sinceLastReport ? 0 : config.cycleWeeks
            Task {
                do { shownID = try await feature.generate(range: range, cycleWeeks: weeks).id } catch { self.error = error.localizedDescription }
            }
        } label: {
            Label(reports.isEmpty ? "Generate" : "New Report", systemImage: "sparkles")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(feature.progress != nil)
        .help("Read your PRs, tickets and activity for \(next.label) and write the highlights")
    }

    private func copy(_ report: BackendReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.markdown, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// The report's bullet list: bold themes, nested chantier items, inline markdown.
struct ReportMarkdown: View {
    let markdown: String
    var limit: Int = .max

    struct Line: Equatable {
        let level: Int
        let text: String
    }

    static func lines(_ markdown: String) -> [Line] {
        markdown.split(separator: "\n").compactMap { raw in
            let indent = raw.prefix { $0 == " " }.count
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            let text = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") ? String(trimmed.dropFirst(2)) : trimmed
            return Line(level: indent >= 2 ? 1 : 0, text: text)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.lines(markdown).prefix(limit).enumerated()), id: \.offset) { _, line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle()
                        .fill(line.level == 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: line.level == 0 ? 6 : 4, height: line.level == 0 ? 6 : 4)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
                    Text((try? AttributedString(markdown: line.text)) ?? AttributedString(line.text))
                        .font(line.level == 0 ? .callout : .callout)
                        .foregroundStyle(line.level == 0 ? .primary : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(line.level) * 18)
            }
        }
        .textSelection(.enabled)
    }
}
