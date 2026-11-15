import DashKit
import DashKitUI
import SwiftData
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

extension TrainCar {
    /// A deployment by id, else a workspace's latest one (cars are newest first).
    static func find(_ text: String, in cars: [TrainCar]) -> TrainCar? {
        cars.first { $0.id == text } ?? cars.first { $0.workspace.caseInsensitiveCompare(text) == .orderedSame }
    }
}

struct TrainCar: Identifiable, Hashable {
    let id: String
    let workspace: String
    let kind: String
    let app: String
    let version: String
    let branch: String
    let by: String
    let at: Date
    let duration: TimeInterval?
    let status: String
    let error: String
}

private struct TrainView: View {
    let config: DeploymentTrainWidget.Config
    /// The widget's DashQL query (its query bar), applied after the settings.
    let query: WidgetQuery?
    let queryText: String
    @State private var queryIDs: [String]?
    /// The deployment the user picked: highlighted and published for linked widgets until another
    /// is picked or it's clicked again.
    @State private var selectedID: String?
    @Query(sort: \WorkspaceDeployment.startedAt, order: .reverse) private var deployments: [WorkspaceDeployment]

    private var all: [TrainCar] {
        deployments.filter { car in
            (config.workspace.isEmpty || car.workspace == config.workspace) && (!config.onlyMine || car.by == (DashStorage.defaults.string(forKey: "workspaces.username") ?? NSUserName()))
        }.prefix(100).map(TrainCar.init)
    }

    var body: some View {
        let all = all
        let cars = QueryRows.ordered(all, by: queryIDs)
        content(cars, total: all.count)
            .task(id: QueryRows.key(queryText, all, row: \.queryRow)) {
                queryIDs = await QueryRows.ids(query, all, row: \.queryRow)
            }
            .onExitCommand { selectedID = nil }
            .reportsSelection(selectedID.flatMap { id in all.first { $0.id == id }?.queryRow })
            .handlesWidgetActions { name, input in
                switch name {
                case "select":
                    let wanted = input["id"]?.string ?? ""
                    guard let car = TrainCar.find(wanted, in: cars) else { throw ToolError("No shown deployment “\(wanted)”.") }
                    selectedID = car.id
                    return ["selected": .string("\(car.workspace) \(car.app) \(car.version)")]
                case "clear_selection":
                    selectedID = nil
                    return "cleared"
                default:
                    throw ToolError("Unknown action \(name).")
                }
            }
    }

    @ViewBuilder
    private func content(_ cars: [TrainCar], total: Int) -> some View {
        if cars.isEmpty {
            ContentUnavailableView("No deployments yet", systemImage: "tram", description: Text("Deploy a worktree to a workspace to start the train."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                QueryCount(shown: cars.count, total: total, query: queryText)
                TrainList(cars: cars, selectedID: selectedID) { car in
                    selectedID = selectedID == car.id ? nil : car.id
                }
            }
        }
    }
}

struct TrainList: View {
    let cars: [TrainCar]
    var selectedID: String? = nil
    /// nil: cars aren't clickable (previews, a workspace's sheet).
    var onSelect: ((TrainCar) -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(cars.enumerated()), id: \.element.id) { index, car in
                    HStack(alignment: .top, spacing: 10) {
                        // The track: a dot per car, a line between them.
                        VStack(spacing: 0) {
                            Circle().fill(color(car.status)).frame(width: 10, height: 10).padding(.top, 4)
                            if index < cars.count - 1 { Rectangle().fill(.quaternary).frame(width: 2).frame(maxHeight: .infinity) }
                        }
                        .frame(width: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(car.workspace).font(.callout.bold().monospaced())
                                Text(title(car)).font(.callout)
                                if !car.version.isEmpty { Text(car.version).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                Spacer()
                                Text(car.at, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                if !car.branch.isEmpty { Label(car.branch, systemImage: "arrow.triangle.branch").lineLimit(1) }
                                Label(car.by, systemImage: "person")
                                if let duration = car.duration { Label(Duration.seconds(duration).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)), systemImage: "timer") }
                                if car.status == "running" { ProgressView().controlSize(.mini) }
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            if !car.error.isEmpty { Text(car.error).font(.caption).foregroundStyle(.red).lineLimit(2) }
                        }
                        .padding(.bottom, 10)
                    }
                    .padding(.horizontal, 4)
                    .background(selectedID == car.id ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
                    .contentShape(.rect)
                    .onTapGesture { onSelect?(car) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func title(_ car: TrainCar) -> String {
        switch car.kind {
        case "worktree": "deployed \(car.app)"
        case "image": "image \(car.app)"
        case "config": "configuration"
        default: "created"
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "succeeded": .green
        case "failed": .red
        default: .orange
        }
    }
}
