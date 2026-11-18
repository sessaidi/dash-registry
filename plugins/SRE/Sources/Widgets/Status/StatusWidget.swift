import DashKit
import DashKitUI
import SwiftUI

/// SRE Status: is prod OK, what needs attention, and the on-call SRE's latest finding.
struct StatusWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        /// Hide warnings and No Data; show only what's critical.
        var criticalOnly: Bool
    }

    static let kind = "sre.status"
    static let displayName = "SRE Status"
    static let summary = "Is prod OK: alerting monitors, unhealthy pods and the on-call SRE's latest finding, with a button to ask it."
    static let systemImage = "stethoscope"
    static let defaultSize = WidgetSize.medium
    static let sizeLimits = GridLimits(minW: 3, minH: 2, maxW: 12, maxH: 16)
    static let defaultConfig = Config(criticalOnly: false)
    static let configSchema: JSONValue = ["type": "object", "properties": ["criticalOnly": ["type": "boolean", "description": "Only critical signals."]]]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        ProvidedWidget(StatusProvider(host: context.host), config: config.wrappedValue, loading: "Checking monitors and pods…") { snapshot, layout in
            // The header button asks about everything; a row or finding asks about itself.
            StatusView(snapshot: snapshot, family: layout.family, ask: { prompt in context.host.askDashii(prompt) },
                       markdown: { context.host.markdown($0) })
        }
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Only critical", isOn: config.criticalOnly)
    }

    static func preview(config: Config) -> some View {
        StatusPreview()
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        (try? await StatusProvider(host: context.host).snapshot(for: config)).map { snapshot in
            snapshot.signals.json.merging(["last_report": snapshot.lastReport.map { .string($0.summary) } ?? .null])
        } ?? .null
    }
}

/// The sample snapshot at whatever size the gallery measures.
private struct StatusPreview: View {
    @Environment(\.widgetLayout) private var layout
    var body: some View { StatusView(snapshot: .sample, family: layout.family) }
}
