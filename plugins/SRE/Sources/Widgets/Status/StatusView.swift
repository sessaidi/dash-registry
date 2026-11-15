import DashKit
import DashKitUI
import SwiftUI

/// Renders a `StatusSnapshot`: a headline, then signals and the SRE's last word as room allows.
struct StatusView: View {
    let snapshot: StatusSnapshot
    let size: WidgetSizeClass
    var ask: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headline
            if size > .compact {
                signals
                if let report = snapshot.lastReport { reportView(report) }
            }
            Spacer(minLength: 0)
        }
        .padding(size == .compact ? 8 : 12)
    }

    private var headline: some View {
        HStack(spacing: 8) {
            StatusDot(tone)
            Text(title).font(size == .compact ? .headline : .title3.weight(.semibold))
            Spacer()
            if let ask, snapshot.level != .ok {
                Button { ask(question) } label: {
                    if size == .large { Label("Ask the SRE", systemImage: "stethoscope") } else { Image(systemName: "stethoscope") }
                }
                .buttonStyle(.borderless)
                .help("Ask Dashii to have the on-call SRE look into it")
            }
        }
    }

    @ViewBuilder private var signals: some View {
        let rows = snapshot.signals.monitors + snapshot.signals.pods
        if rows.isEmpty {
            Text(snapshot.level == .unknown ? "Turn on Datadog Monitors or Kubernetes Pods to watch something." : "Nothing alerting, every pod healthy.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(rows.prefix(size == .large ? 8 : 4)) { signal in
                ItemRow(signal.title, subtitle: signal.detail) {
                    Image(systemName: signal.level == .critical ? "exclamationmark.octagon.fill" : "exclamationmark.triangle")
                        .foregroundStyle(signal.level == .critical ? Tone.danger.color : Tone.warning.color)
                }
            }
            if rows.count > (size == .large ? 8 : 4) {
                Text("+\(rows.count - (size == .large ? 8 : 4)) more").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func reportView(_ report: StatusSnapshot.Report) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("On-call SRE", systemImage: "stethoscope").font(.caption.bold()).foregroundStyle(.secondary)
                RelativeTime(report.at).font(.caption).foregroundStyle(.secondary)
            }
            Text(report.summary).font(.callout).lineLimit(size == .large ? 6 : 3)
            if size == .large {
                ForEach(report.findings, id: \.self) { Text("• \($0)").font(.caption) }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private var tone: Tone {
        switch snapshot.level {
        case .ok: .success
        case .degraded: .warning
        case .down: .danger
        case .unknown: .neutral
        }
    }

    private var title: String {
        switch snapshot.level {
        case .ok: "All clear"
        case .degraded: "Degraded"
        case .down: "Something is down"
        case .unknown: "Nothing to watch yet"
        }
    }

    private var question: String {
        "What's going on? " + (snapshot.signals.monitors + snapshot.signals.pods).prefix(5).map { "\($0.title) (\($0.detail))" }.joined(separator: "; ")
    }
}
