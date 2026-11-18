import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// Renders a `StatusSnapshot` with one layout per size family:
/// - narrow: the verdict and the few most urgent signals;
/// - medium: the verdict, the signals with their detail, the SRE's last word;
/// - wide: monitors and pods side by side as lanes, with the SRE's report beside them;
/// - large: a summary strip, the signals grouped by source, and the SRE's report with its findings.
struct StatusView: View {
    let snapshot: StatusSnapshot
    let family: WidgetLayout.Family
    /// Sends a prompt to Dashii: the whole status from the header, one item from its row.
    var ask: ((String) -> Void)?
    /// Draws the report the way Dash draws notes (nil: inline Markdown, as in previews).
    var markdown: ((String) -> AnyView)?

    var body: some View {
        Group {
            switch family {
            case .narrow: StatusNarrowView(snapshot: snapshot)
            case .wide: StatusWideView(snapshot: snapshot)
            case .large: StatusLargeView(snapshot: snapshot)
            default: StatusMediumView(snapshot: snapshot)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Each signal and finding can be asked about on its own (hover buttons, right-click).
        .environment(\.sreAsk, ask)
        .environment(\.sreMarkdown, markdown)
        .widgetHeader {
            if let ask, snapshot.level != .ok {
                Button { ask("Ask the on-call SRE (agent sre.oncall ask): \(snapshot.question)") } label: {
                    if family == .narrow || family == .medium {
                        Image(systemName: "stethoscope")
                    } else {
                        Label("Ask the SRE", systemImage: "stethoscope")
                    }
                }
                .buttonStyle(.borderless)
                .help("Ask Dashii to have the on-call SRE look into it")
            }
        }
    }
}

// MARK: - Families

/// Narrow: the verdict with its count, then the three most urgent signals, one short line each.
struct StatusNarrowView: View {
    let snapshot: StatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StatusHeadline(snapshot: snapshot, font: .headline)
            if snapshot.allSignals.isEmpty {
                StatusQuietNote(snapshot: snapshot)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(snapshot.allSignals.prefix(3)) { signal in
                        HStack(spacing: 6) {
                            SignalIcon(level: signal.level)
                            Text(signal.title).font(.callout).lineLimit(1).truncationMode(.tail)
                        }
                        .help(signal.detail)
                        .modifier(SignalActions(signal: signal))
                    }
                }
                if snapshot.allSignals.count > 3 {
                    Text("+\(snapshot.allSignals.count - 3) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Medium: the verdict, every signal with its detail line, and the SRE's last word.
struct StatusMediumView: View {
    let snapshot: StatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeadline(snapshot: snapshot, font: .title3.weight(.semibold))
            if snapshot.allSignals.isEmpty {
                StatusQuietNote(snapshot: snapshot)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.allSignals) { SignalRow(signal: $0) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            if let report = snapshot.lastReport {
                ReportPanel(report: report, summaryLines: 2, showsFindings: false)
            }
        }
    }
}

/// Wide: the room goes to lanes. Monitors and pods each get a column; the SRE's report takes the third.
struct StatusWideView: View {
    let snapshot: StatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            StatusHeadline(snapshot: snapshot, font: .title3.weight(.semibold))
            HStack(alignment: .top, spacing: 16) {
                SignalLane(title: "Monitors", systemImage: "bell.badge", signals: snapshot.signals.monitors,
                           empty: snapshot.signals.sources.contains("datadog") ? "Nothing alerting" : "Datadog not watched")
                SignalLane(title: "Pods", systemImage: "cube.box", signals: snapshot.signals.pods,
                           empty: snapshot.signals.sources.contains("kubernetes") ? "Every pod healthy" : "Kubernetes not watched")
                if let report = snapshot.lastReport {
                    ReportPanel(report: report, summaryLines: 5, showsFindings: true)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Large: a summary strip, the signals grouped by source, and the SRE's report with every finding.
struct StatusLargeView: View {
    let snapshot: StatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusHeadline(snapshot: snapshot, font: .title2.weight(.semibold))
            StatusSummaryStrip(snapshot: snapshot)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if snapshot.allSignals.isEmpty {
                            StatusQuietNote(snapshot: snapshot)
                        }
                        if !snapshot.signals.monitors.isEmpty {
                            SignalGroup(title: "Datadog monitors", systemImage: "bell.badge", signals: snapshot.signals.monitors)
                        }
                        if !snapshot.signals.pods.isEmpty {
                            SignalGroup(title: "Kubernetes pods", systemImage: "cube.box", signals: snapshot.signals.pods)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 12) {
                    if let report = snapshot.lastReport {
                        ReportPanel(report: report, summaryLines: nil, showsFindings: true)
                    } else {
                        Text("The on-call SRE hasn't reported yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    SourcesFooter(sources: snapshot.signals.sources)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}

// MARK: - Pieces

/// The verdict: a dot in the status tone, the title and a short count.
private struct StatusHeadline: View {
    let snapshot: StatusSnapshot
    let font: Font

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(snapshot.tone)
            Text(snapshot.title).font(font).lineLimit(1)
            if let count = snapshot.countLine {
                Text(count).font(.callout).foregroundStyle(snapshot.tone.color).lineLimit(1)
            }
        }
    }
}

/// What a quiet (or unwatched) status says.
private struct StatusQuietNote: View {
    let snapshot: StatusSnapshot

    var body: some View {
        Text(snapshot.level == .unknown ? "Turn on Datadog Monitors or Kubernetes Pods to watch something." : "Nothing alerting, every pod healthy.")
            .font(.callout).foregroundStyle(.secondary)
    }
}

private struct SignalIcon: View {
    let level: Signal.Level

    var body: some View {
        Image(systemName: level == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(level.tone.color)
            .accessibilityLabel(level == .critical ? "Critical" : "Warning")
    }
}

/// One signal with its detail line, and buttons to ask about it alone.
private struct SignalRow: View {
    let signal: Signal

    var body: some View {
        ItemRow(signal.title, subtitle: signal.detail) { SignalIcon(level: signal.level) }
            .modifier(SignalActions(signal: signal))
    }
}

/// What asking about one item means.
enum SREQuestion {
    /// The on-call SRE agent investigates it: cause, evidence, what to do.
    case investigate
    /// Dashii explains it in plain words.
    case explain

    func prompt(about subject: String) -> String {
        switch self {
        case .investigate:
            "Ask the on-call SRE (agent sre.oncall ask): investigate only this, not the rest of the status: \(subject). Why is it failing, since when, what changed (deploys, config, dependencies), and what should I do?"
        case .explain:
            "Explain this to me in plain words, on its own: \(subject). What does it mean, what usually causes it, and how bad is it? Look at its details (logs, events, monitor) if you can."
        }
    }
}

extension EnvironmentValues {
    /// Sends a question about one item to Dashii (nil: no asking, as in previews).
    @Entry var sreAsk: ((String) -> Void)?
    /// Draws the SRE's report as a Dash note (nil: inline Markdown, as in previews).
    @Entry var sreMarkdown: ((String) -> AnyView)?
}

extension Signal {
    /// The item as the SRE and Dashii should read it.
    var subject: String {
        let kind = id.contains("/") ? "pod \(id)" : "monitor \(id)"
        return "\(title) (\(kind): \(detail))"
    }
}

/// Hover buttons and a right-click menu that ask about one signal.
private struct SignalActions: ViewModifier {
    let signal: Signal
    @Environment(\.sreAsk) private var ask
    @State private var hovering = false

    func body(content: Content) -> some View {
        if let ask {
            content
                .overlay(alignment: .trailing) {
                    if hovering {
                        HStack(spacing: 2) {
                            Button { ask(SREQuestion.explain.prompt(about: signal.subject)) } label: { Image(systemName: "questionmark.bubble") }
                                .help("Explain this")
                            Button { ask(SREQuestion.investigate.prompt(about: signal.subject)) } label: { Image(systemName: "stethoscope") }
                                .help("Ask the SRE to investigate this")
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: .capsule)
                    }
                }
                .onHover { hovering = $0 }
                .contextMenu {
                    Button("Explain This", systemImage: "questionmark.bubble") { ask(SREQuestion.explain.prompt(about: signal.subject)) }
                    Button("Ask the SRE to Investigate", systemImage: "stethoscope") { ask(SREQuestion.investigate.prompt(about: signal.subject)) }
                    Divider()
                    Button("Copy", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("\(signal.title) — \(signal.detail)", forType: .string)
                    }
                }
        } else {
            content
        }
    }
}

/// A column of signals from one source, for the wide layout.
private struct SignalLane: View {
    let title: String
    let systemImage: String
    let signals: [Signal]
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !signals.isEmpty { Badge("\(signals.count)", tone: signals.worstTone) }
            }
            if signals.isEmpty {
                Label(empty, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(signals) { SignalRow(signal: $0) }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// A titled group of signals, for the large layout.
private struct SignalGroup: View {
    let title: String
    let systemImage: String
    let signals: [Signal]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(title, systemImage: systemImage).font(.subheadline.weight(.semibold))
                Badge("\(signals.count)", tone: signals.worstTone)
            }
            ForEach(signals) { SignalRow(signal: $0) }
        }
    }
}

/// Counts across the top of the large layout.
private struct StatusSummaryStrip: View {
    let snapshot: StatusSnapshot

    var body: some View {
        let critical = snapshot.allSignals.count { $0.level == .critical }
        let warning = snapshot.allSignals.count - critical
        HStack(alignment: .top, spacing: 16) {
            MetricView("\(critical)", label: "Critical", tone: critical > 0 ? .danger : .neutral)
            MetricView("\(warning)", label: "Warning", tone: warning > 0 ? .warning : .neutral)
            MetricView("\(snapshot.signals.monitors.count)", label: "Monitors alerting")
            MetricView("\(snapshot.signals.pods.count)", label: "Pods unhealthy")
        }
    }
}

/// The on-call SRE's latest report. Click it for the whole report.
private struct ReportPanel: View {
    let report: StatusSnapshot.Report
    /// nil shows the whole summary.
    let summaryLines: Int?
    let showsFindings: Bool
    @State private var showsReport = false

    var body: some View {
        panel
            .contentShape(.rect)
            .onTapGesture { showsReport = true }
            .help("Show the whole report")
            .accessibilityAddTraits(.isButton)
            .sheet(isPresented: $showsReport) { ReportSheet(report: report) }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("On-call SRE", systemImage: "stethoscope").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if report.critical { Badge("critical", tone: .danger) }
                Spacer(minLength: 4)
                RelativeTime(report.at).font(.caption).foregroundStyle(.secondary)
            }
            Text(ReportSheet.markdown(report.summary)).font(.callout).lineLimit(summaryLines).fixedSize(horizontal: false, vertical: summaryLines == nil)
            if showsFindings, !report.findings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.findings, id: \.self) { finding in
                        Label(finding, systemImage: "arrow.turn.down.right").font(.caption).lineLimit(2)
                            .modifier(FindingActions(finding: finding))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}

/// The on-call SRE's report in full, drawn as a Dash note: the summary, then every finding with
/// its target, evidence and suggestion.
struct ReportSheet: View {
    let report: StatusSnapshot.Report
    @Environment(\.dismiss) private var dismiss
    @Environment(\.sreAsk) private var ask
    @Environment(\.sreMarkdown) private var markdown

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("On-call SRE", systemImage: "stethoscope").font(.title3.weight(.semibold))
                if report.critical { Badge("critical", tone: .danger) }
                Spacer()
                Text(report.at.formatted(date: .abbreviated, time: .shortened)).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                Group {
                    if let markdown {
                        markdown(report.markdown)
                    } else {
                        Text(Self.markdown(report.markdown)).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let ask {
                    Button("Ask the SRE About This Report", systemImage: "stethoscope") {
                        ask("Ask the on-call SRE (agent sre.oncall ask): about your latest report (\(report.at.formatted(date: .omitted, time: .shortened))): what's the evidence, and what should I do first?")
                        dismiss()
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 560)
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// A right-click menu on one finding of the SRE's report.
private struct FindingActions: ViewModifier {
    let finding: String
    @Environment(\.sreAsk) private var ask

    func body(content: Content) -> some View {
        if let ask {
            content.contextMenu {
                Button("Explain This", systemImage: "questionmark.bubble") { ask(SREQuestion.explain.prompt(about: "the SRE's finding “\(finding)”")) }
                Button("Ask the SRE for More", systemImage: "stethoscope") {
                    ask("Ask the on-call SRE (agent sre.oncall ask): about your finding “\(finding)” only: the evidence, and exactly what to do.")
                }
            }
        } else {
            content
        }
    }
}

/// Which extensions the status reads.
private struct SourcesFooter: View {
    let sources: [String]

    var body: some View {
        if !sources.isEmpty {
            HStack(spacing: 4) {
                Text("Watching").font(.caption).foregroundStyle(.secondary)
                ForEach(sources, id: \.self) { Badge($0, tone: .info) }
            }
        }
    }
}

// MARK: - Presentation

extension Signal.Level {
    var tone: Tone {
        switch self {
        case .critical: .danger
        case .warning: .warning
        case .unknown: .neutral
        }
    }
}

extension [Signal] {
    /// The tone of the worst signal; success when there are none.
    var worstTone: Tone { map(\.level).min()?.tone ?? .success }
}

extension StatusSnapshot {
    /// Monitors then pods, each worst first.
    var allSignals: [Signal] { signals.monitors + signals.pods }

    var tone: Tone {
        switch level {
        case .ok: .success
        case .degraded: .warning
        case .down: .danger
        case .unknown: .neutral
        }
    }

    var title: String {
        switch level {
        case .ok: "All clear"
        case .degraded: "Degraded"
        case .down: "Something is down"
        case .unknown: "Nothing to watch yet"
        }
    }

    /// "2 critical · 1 warning", or nil when quiet.
    var countLine: String? {
        let critical = allSignals.count { $0.level == .critical }
        let other = allSignals.count - critical
        let parts = [critical > 0 ? "\(critical) critical" : nil, other > 0 ? "\(other) warning" : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What the Ask button sends: the first few signals.
    var question: String {
        "What's going on? " + allSignals.prefix(5).map { "\($0.title) (\($0.detail))" }.joined(separator: "; ")
    }
}
