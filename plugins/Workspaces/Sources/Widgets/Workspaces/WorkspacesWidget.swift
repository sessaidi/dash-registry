import DashKit
import DashKitUI
import SwiftUI

/// Workspaces: the backend workspaces list. It observes `WorkspacesFeature`, whose poller keeps
/// the list fresh, and publishes the picked workspace to linked widgets.
struct WorkspacesWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var onlyMine: Bool
    }

    static let kind = "workspaces.list"
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 12, maxH: 20)
    static let displayName = "Workspaces"
    static let summary = "Backend workspaces on GKE: owner, node pool, last deploy, persist flag. Open one for pods and actions."
    static let systemImage = "shippingbox"
    static let defaultConfig = Config(onlyMine: true)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["onlyMine": ["type": "boolean", "description": "Only workspaces deployed by the user."]],
    ]

    static let queryFields = WorkspaceItem.queryFields
    static let actions = [
        WidgetAction(name: "select", description: "Select a workspace by name; linked widgets follow the selection. Temporary.",
                     properties: ["name": JSONSchema.string("Workspace name.")], required: ["name"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected workspace."),
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        WorkspaceList(feature: context.host.ext(WorkspacesFeature.self), host: context.host, onlyMine: config.wrappedValue.onlyMine,
                      query: context.query(fields: WorkspaceItem.queryFields), queryText: context.queryText)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Only mine", isOn: config.onlyMine)
    }

    /// Sample workspaces, no cluster: the gallery and Settings render this.
    static func preview(config: Config) -> some View {
        let items = WorkspaceItem.samples.filter { !config.onlyMine || $0.deployedBy == WorkspaceItem.sampleUser }
        return WorkspaceListContent(scope: "dev/us", items: items, busy: ["checkout-flow"], isLoading: false, error: nil)
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let feature = context.host.ext(WorkspacesFeature.self) else { return [] }
        return .array(feature.visible(onlyMine: config.onlyMine).map(WorkspacesFeature.json))
    }
}
