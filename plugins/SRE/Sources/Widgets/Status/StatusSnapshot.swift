import DashKit
import Foundation

/// What the SRE Status widget shows: plain data, so previews and tests need no services.
struct StatusSnapshot: Sendable, Equatable {
    struct Report: Sendable, Equatable {
        var summary: String
        var at: Date
        var findings: [String]
        var critical: Bool
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
                       Signal(id: "1188", title: "checkout p95 latency", detail: "Warn · service checkout · env prod", level: .warning, since: nil)],
            pods: [Signal(id: "papi-eu/api-7d9f8-x2k", title: "Pod api-7d9f8-x2k", detail: "CrashLoopBackOff in papi-eu · 14 restarts · BackOff",
                          level: .critical, since: nil)],
            sources: ["datadog", "kubernetes"]),
        lastReport: Report(summary: "5xx on api started at 10:02 with v1.42 rolling out; the new pods crash-loop on a missing config key.",
                           at: .now.addingTimeInterval(-600), findings: ["Roll back api to v1.41", "Add the key to the config map"], critical: true))
}
