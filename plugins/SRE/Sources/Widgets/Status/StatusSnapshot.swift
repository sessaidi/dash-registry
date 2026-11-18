import DashKit
import Foundation

/// What the SRE Status widget shows: plain data, so previews and tests need no services.
struct StatusSnapshot: Sendable, Equatable {
    struct Report: Sendable, Equatable {
        var summary: String
        var at: Date
        /// The three most severe findings' titles, for the panel.
        var findings: [String]
        var critical: Bool
        /// Every finding in full, for the report sheet.
        var items: [AgentFinding] = []
    }

    var signals: Signals
    var lastReport: Report?

    enum Level: Sendable { case ok, degraded, down, unknown }

    var level: Level {
        if signals.sources.isEmpty { return .unknown }
        if signals.monitors.contains(where: { $0.level == .critical }) || signals.pods.contains(where: { $0.level == .critical }) { return .down }
        return signals.isQuiet ? .ok : .degraded
    }

    static let sample = StatusSnapshot(
        signals: Signals(
            monitors: [Signal(id: "1201", title: "api 5xx rate", detail: "Alert · service api · env prod", level: .critical, since: nil),
                       Signal(id: "1188", title: "checkout p95 latency", detail: "Warn · service checkout · env prod", level: .warning, since: nil),
                       Signal(id: "1093", title: "worker queue depth", detail: "Warn · service worker · env prod", level: .warning, since: nil)],
            pods: [Signal(id: "bill-eu/api-7d9f8-x2k", title: "Pod api-7d9f8-x2k", detail: "CrashLoopBackOff in bill-eu · 14 restarts · BackOff",
                          level: .critical, since: nil),
                   Signal(id: "bill-eu/api-7d9f8-q4m", title: "Pod api-7d9f8-q4m", detail: "CrashLoopBackOff in bill-eu · 9 restarts · BackOff",
                          level: .critical, since: nil),
                   Signal(id: "bill-us/worker-5c4b-mn3", title: "Pod worker-5c4b-mn3", detail: "Running in bill-us · 2 restarts · Unhealthy",
                          level: .warning, since: nil)],
            sources: ["datadog", "kubernetes"]),
        lastReport: Report(summary: "5xx on api started at 10:02 with v1.42 rolling out; the new pods crash-loop on a missing config key.",
                           at: .now.addingTimeInterval(-600), findings: ["Roll back api to v1.41", "Add FEATURE_FLAGS_URL to the api config map", "Checkout latency follows the api errors"], critical: true))
}

extension StatusSnapshot.Report {
    /// The report in Dash's note syntax: the summary as a callout, then one callout per finding in
    /// its severity's colour, with the target, the evidence and what to do.
    var markdown: String {
        var lines = ["> [!summary] Summary"] + Self.quoted(summary)
        if !items.isEmpty { lines += ["", "## Findings"] }
        for finding in items {
            let title = finding.title.replacingOccurrences(of: "\n", with: " ")
            lines += ["", "> [!\(Self.callout(finding.severity))] \(title)"]
            if !finding.target.isEmpty { lines.append("> `\(finding.target.replacingOccurrences(of: "`", with: "'"))`") }
            if !finding.detail.isEmpty { lines += [">"] + Self.quoted(finding.detail) }
            let suggestion = finding.suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
            if suggestion.contains("\n") {
                lines += [">", "> **What to do**", ">"] + Self.quoted(suggestion)
            } else if !suggestion.isEmpty {
                lines += [">", "> **What to do:** \(suggestion)"]
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func callout(_ severity: AgentFinding.Severity) -> String {
        switch severity {
        case .critical: "danger"
        case .warning: "warning"
        default: "note"
        }
    }

    /// Every line inside the callout, blank ones included, so lists and code blocks stay in it.
    private static func quoted(_ text: String) -> [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }
    }
}
