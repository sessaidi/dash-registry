import DashKit

/// Signals from the other extensions, plus the on-call SRE's latest report. No model call.
struct StatusProvider: WidgetDataProvider {
    let host: any ExtensionContext

    var refresh: WidgetRefresh { .every(.seconds(60)) }

    func snapshot(for config: StatusWidget.Config) async throws -> StatusSnapshot {
        var signals = await Ops(host: host).signals()
        if config.criticalOnly {
            signals.monitors.removeAll { $0.level != .critical }
            signals.pods.removeAll { $0.level != .critical }
        }
        let report = host.agentReports("sre.oncall", limit: 5).first { $0.status != .skipped }.map { report in
            StatusSnapshot.Report(summary: report.summary, at: report.finishedAt,
                                  findings: report.findings.sorted { $0.severity > $1.severity }.prefix(3).map(\.title),
                                  critical: report.severity == .critical,
                                  items: report.findings.sorted { $0.severity > $1.severity })
        }
        return StatusSnapshot(signals: signals, lastReport: report)
    }
}
