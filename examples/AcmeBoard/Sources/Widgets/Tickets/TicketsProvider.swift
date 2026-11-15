import DashKit

/// Where the widget's data comes from. Views never fetch; they render what this returns.
struct TicketsProvider: WidgetDataProvider {
    let host: any ExtensionContext

    /// The feature refreshes from Acme every minute; reading its copy is cheap.
    var refresh: WidgetRefresh { .every(.seconds(30)) }

    func snapshot(for config: TicketsWidget.Config) async throws -> TicketsSnapshot {
        guard let feature = host.ext(AcmeBoardFeature.self) else { throw ToolError("Acme Board isn't loaded.") }
        // The last read failed: try again now (this is also what Retry does), and if it still
        // fails, say so. The widget keeps the last good snapshot and shows it as stale.
        if feature.lastError != nil { await feature.refresh() }
        if let error = feature.lastError { throw ToolError(error) }
        let order = ["urgent", "high", "normal", "low"]
        let tickets = feature.tickets
            .filter { config.showDone || $0.status != "done" }
            .sorted { (order.firstIndex(of: $0.priority) ?? 9) < (order.firstIndex(of: $1.priority) ?? 9) }
        let triage = host.agentReports("acme-board.triage", limit: 5).first { $0.status != .skipped }?.summary
        return TicketsSnapshot(tickets: tickets, triage: triage)
    }
}
