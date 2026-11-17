import DashKit
import DashKitUI
import Foundation
import Observation
import SwiftUI

/// The Monitors feature: Datadog monitors that aren't OK, refreshed every minute, with activity
/// when one starts alerting.
@MainActor
@Observable
final class DatadogMonitorsFeature: DashExtension {
    let id = "datadog-monitors"
    let name = "Datadog Monitors"
    let systemImage = "bell.badge"
    let metadata = ExtensionMetadata(
        version: "1.5.0", author: .dash,
        summary: "A dashboard widget of the Datadog monitors in Alert, Warn or No Data, with activity when one starts alerting.",
        category: .monitoring, tags: ["datadog", "monitors", "alerts"], minimumDashKit: "2.4.0")
    let requires = ["datadog"]

    static let interval: Duration = .seconds(60)

    private(set) var monitors: [DatadogMonitor] = []
    private(set) var error: String?
    private(set) var lastUpdated: Date?
    private(set) var loading = false
    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private var poll: Task<Void, Never>?

    var widgets: [WidgetType] { [WidgetType(DatadogMonitorsWidget.self)] }

    var datadog: DatadogIntegration? { host?.integration(DatadogIntegration.self) }

    func start(host: any ExtensionContext) {
        self.host = host
        poll?.cancel()
        poll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func stop() {
        poll?.cancel()
        poll = nil
    }

    func refresh() async {
        guard let datadog, datadog.isConnected else {
            error = nil
            monitors = []
            return
        }
        loading = true
        defer { loading = false }
        do {
            let current = DatadogMonitor.list(try await datadog.get("/api/v1/monitor/search", ["query": #"status:(alert OR warn OR "no data")"#, "per_page": "100"]))
                .sorted { ($0.severity, $0.name) < ($1.severity, $1.name) }
            // A monitor that wasn't alerting at the last check and is now.
            if lastUpdated != nil, let host {
                let before = Set(monitors.filter { $0.severity == 0 }.map(\.id))
                for monitor in current where monitor.severity == 0 && !before.contains(monitor.id) {
                    host.emit("datadog.alert", from: self, title: "Datadog: \(monitor.name) is alerting",
                              link: monitorURL(monitor)?.absoluteString, importance: .notable)
                }
            }
            monitors = current
            error = nil
            lastUpdated = .now
        } catch {
            self.error = error.localizedDescription
        }
    }

    func monitorURL(_ monitor: DatadogMonitor) -> URL? {
        datadog.map { $0.appURL.appending(path: "monitors/\(monitor.id)") }
    }
}
