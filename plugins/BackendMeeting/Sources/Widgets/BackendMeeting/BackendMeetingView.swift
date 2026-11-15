import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// The latest (or a chosen past) report, with the range the next one covers and Generate.
struct BackendMeetingView: View {
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
