import DashKit
import DashKitUI
import SwiftUI

/// Every deployment to workspaces as a timeline: what shipped (app, commit or tag), from which
/// branch, by whom, when, how long it took and whether it worked.
struct DeploymentTrainWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var onlyMine: Bool
        /// One workspace, or empty for all.
        var workspace: String
    }

    static let kind = "workspaces.train"
    static let displayName = "Deployment Train"
    static let summary = "Deployments to workspaces over time: app, version, branch, who, duration and result."
    static let systemImage = "tram"
    static let defaultSize = WidgetSize.wide
    static let sizeLimits = GridLimits(minW: 4, minH: 4, maxW: 12, maxH: 24)
    static let defaultConfig = Config(onlyMine: true, workspace: "")
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["onlyMine": ["type": "boolean"], "workspace": ["type": "string", "description": "Workspace name, or empty for all."]],
    ]

    static let queryFields = TrainCar.queryFields
    static let actions = [
        WidgetAction(name: "select", description: "Select a deployment (its id, or the latest one of a workspace by name); linked widgets follow the selection. Temporary.",
                     properties: ["id": JSONSchema.string("Deployment id or workspace name.")], required: ["id"]),
        WidgetAction(name: "clear_selection", description: "Unselect the selected deployment."),
    ]

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        TrainView(config: config.wrappedValue, query: context.query(fields: TrainCar.queryFields), queryText: context.queryText)
    }

    static func settings(config: Binding<Config>, context: WidgetContext) -> some View {
        Toggle("Only mine", isOn: config.onlyMine)
        TextField("Workspace", text: config.workspace, prompt: Text("All"))
    }

    static func preview(config: Config) -> some View {
        TrainList(cars: [
            .init(id: "1", workspace: "laf-5680", kind: "worktree", app: "services-presentation-api", version: "a1b2c3d", branch: "feat/laf-5680-renewals",
                  by: "ada", at: .now.addingTimeInterval(-600), duration: 312, status: "succeeded", error: ""),
            .init(id: "2", workspace: "laf-5680", kind: "config", app: "", version: "", branch: "", by: "ada", at: .now.addingTimeInterval(-3600),
                  duration: 8, status: "succeeded", error: ""),
            .init(id: "3", workspace: "ops-212", kind: "worktree", app: "services-user", version: "9f8e7d6", branch: "fix/ops-212", by: "sam",
                  at: .now.addingTimeInterval(-7200), duration: 95, status: "failed", error: "CrashLoopBackOff"),
        ])
    }

    @MainActor
    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        let feature = context.host.ext(WorkspacesFeature.self)
        return .array((feature?.train(workspace: config.workspace.isEmpty ? nil : config.workspace, mine: config.onlyMine, limit: 20) ?? []).map { car in
            ["workspace": .string(car.workspace), "kind": .string(car.kind), "app": .string(car.app), "tag": .string(car.tag), "commit": .string(car.commit),
             "branch": .string(car.branch), "by": .string(car.by), "at": .string(car.startedAt.formatted(.iso8601)), "status": .string(car.status), "error": .string(car.error)]
        })
    }
}
