import DashKit
import DashKitUI
import SwiftUI

/// The Acme tickets widget's manifest: what it is, its sizes, its settings and what Dashii may do
/// with it. Data comes from `TicketsProvider`; `TicketsView` draws it.
struct TicketsWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var showDone = false
    }

    static let kind = "acme-board.tickets"
    static let displayName = "Acme Tickets"
    static let summary = "Your Acme tickets: a count when small, a list, columns, or columns with the triage report."
    static let systemImage = "ticket"
    static let defaultSize = WidgetSize.medium
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let defaultConfig = Config()
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["showDone": ["type": "boolean", "description": "Also show done tickets."]],
    ]
    static let actions = [
        WidgetAction(name: "search", description: "Show only tickets whose id or title contains the text. Empty clears it.",
                     properties: ["text": JSONSchema.string("Search text.")], required: ["text"]),
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        ProvidedWidget(TicketsProvider(host: context.host), config: config.wrappedValue) { snapshot, layout in
            TicketsView(snapshot: snapshot, family: layout.family)
        }
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Show done tickets", isOn: config.showDone)
    }

    /// Sample data for the gallery: no network, no accounts. The gallery measures it like a real
    /// card, so each size shows its own layout.
    static func preview(config: Config) -> some View { TicketsPreview() }

    /// What Dashii reads when it looks at the widget.
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let snapshot = try? await TicketsProvider(host: context.host).snapshot(for: config) else { return .null }
        return ["tickets": .array(snapshot.tickets.map(\.json)), "triage": snapshot.triage.map { .string($0) } ?? .null]
    }
}
