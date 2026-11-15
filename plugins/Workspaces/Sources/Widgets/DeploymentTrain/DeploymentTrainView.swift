import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// The widget body: deployments from SwiftData (live as they're recorded), after the settings and
/// the query bar, with selection and actions.
struct TrainView: View {
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
