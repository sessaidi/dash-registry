import DashKit
import DashKitUI
import SwiftUI

/// The Containers widget: observes `DockerContainersFeature` (its 15 s poller) and applies
/// "show stopped" and the query bar.
struct ContainersView: View {
    let showStopped: Bool
    let host: any ExtensionContext
    /// The widget's DashQL query (its query bar), applied after "show stopped".
    var query: WidgetQuery?
    var queryText = ""
    @State private var queryIDs: [String]?

    var body: some View {
        if let feature = host.ext(DockerContainersFeature.self) {
            content(feature)
        } else {
            StateView(.needsConnection(names: ["Docker"]), action: ("Open Extensions", { host.openManager("docker") }))
        }
    }

    @ViewBuilder
    private func content(_ feature: DockerContainersFeature) -> some View {
        let all = feature.containers
            .filter { showStopped || $0.state == "running" }
            .sorted { ($0.stateRank, $0.name) < ($1.stateRank, $1.name) }
        let shown = QueryRows.ordered(all, by: queryIDs)
        Group {
            if feature.lastUpdated == nil {
                if let error = feature.error {
                    StateView(.failed(message: error), action: ("Retry", { Task { await feature.refresh() } }))
                } else {
                    StateView(.loading("Loading containers…"))
                }
            } else if shown.isEmpty {
                StateView(.empty(title: "No containers", systemImage: "shippingbox", message: showStopped ? nil : "Nothing is running."))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    QueryCount(shown: shown.count, total: all.count, query: queryText)
                    List(shown) { container in
                        ItemRow(container.name, subtitle: "\(container.image) · \(container.status)", leading: {
                            StatusDot(container.tone, help: container.state)
                        }, trailing: {
                            Badge(container.badgeText, tone: container.tone)
                        })
                    }
                    .listStyle(.plain)
                    if let error = feature.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
        .task(id: QueryRows.key(queryText, all, row: \.queryRow)) {
            queryIDs = await QueryRows.ids(query, all, row: \.queryRow)
        }
    }
}
