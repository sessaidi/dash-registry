import AppKit
import DashKit
import DashKitUI
import SwiftUI

/// The Pods widget: observes `PodsFeature.browsing` (refreshed on the widget's own interval),
/// applies Dashii's temporary changes and the query bar, and publishes the selection.
struct PodsWidgetView: View {
    let feature: PodsFeature?
    let host: any ExtensionContext
    /// The widget's saved settings.
    @Binding var settings: PodsWidget.Config
    /// The widget's DashQL query (its query bar), applied after the settings' filters.
    let query: WidgetQuery?
    let queryText: String
    /// The pod whose detail sheet is open.
    @State private var opened: PodSummary?
    /// The pod the user picked: highlighted and published for linked widgets until another is
    /// picked or it's clicked again.
    @State private var selectedID: String?
    /// What Dashii's actions changed for now (namespace, context, filters); the saved settings
    /// stay, and this resets when they change.
    @State private var override: PodsWidget.Config?
    @State private var queryIDs: [String]?

    /// The settings with Dashii's temporary changes on top: what the widget shows.
    private var config: PodsWidget.Config { override ?? settings }
    /// The widget's size family, from the dashboard: each gets its own layout.
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        main
            .handlesWidgetActions { name, input in
                if name == "clear_selection" {
                    selectedID = nil
                    return "cleared"
                }
                if name == "clear_filters" {
                    override = nil
                    return "cleared"
                }
                // Actions change what's shown for now, never the saved settings.
                var view = config
                let result = try PodsWidgetActions.perform(name, input, config: &view, pods: visiblePods)
                override = view == settings ? nil : view
                if let pod = result.select {
                    selectedID = pod.id
                    opened = pod
                }
                return result.reply
            }
            .onChange(of: settings) { override = nil }
            .onExitCommand { selectedID = nil }
            .reportsSelection(selectedPod.map(row))
            .reportsWidgetState(PodsWidgetActions.state(config: config, pods: visiblePods, total: browse?.pods.count ?? 0,
                                                        namespace: feature.map(namespaceLabel) ?? "", selected: opened)
                .merging(["selected": selectedPod.map { .string($0.id) } ?? .null, "temporary_changes": .bool(override != nil)]))
            .task(id: QueryRows.key(queryText, filteredPods, row: row)) {
                queryIDs = await QueryRows.ids(query, filteredPods, row: row)
            }
    }

    private var browse: PodsFeature.Browse? { feature?.browsing[config.browseKey] }

    /// The pods the settings' filters keep, sorted.
    private var filteredPods: [PodSummary] {
        let browse = browse
        return PodSummary.sorted((browse?.pods ?? []).filter { config.query.matches($0, warnings: browse?.warnings[$0.id] ?? []) }, by: config.podSort)
    }

    /// The pods the widget lists: the settings' filters, then the DashQL query.
    private var visiblePods: [PodSummary] { QueryRows.ordered(filteredPods, by: queryIDs) }

    private var selectedPod: PodSummary? { selectedID.flatMap { id in browse?.pods.first { $0.id == id } } }

    /// Clicking a pod selects it and opens its detail; clicking the selected one again unselects it.
    private func pick(_ pod: PodSummary) {
        if selectedID == pod.id {
            selectedID = nil
        } else {
            selectedID = pod.id
            opened = pod
        }
    }

    private func row(_ pod: PodSummary) -> JSONValue { pod.queryRow(context: config.context, warnings: browse?.warnings[pod.id] ?? []) }

    @ViewBuilder private var main: some View {
        if let feature {
            content(feature)
                .environment(\.podSelectedID, selectedID)
                .sheet(item: $opened) { PodDetailSheet(pod: $0, context: config.context, feature: feature, host: host) { await feature.refresh(browsing: config.browseKey) } }
                // Each widget refreshes on its own interval; restarts when its settings change.
                .task(id: "\(config.browseKey.hashValue)|\(config.refreshInterval)") {
                    while !Task.isCancelled {
                        await feature.refresh(browsing: config.browseKey)
                        try? await Task.sleep(for: .seconds(config.refreshInterval))
                    }
                }
        } else {
            StateView(.failed(message: "The Pods feature isn't loaded."))
        }
    }

    @ViewBuilder
    private func content(_ feature: PodsFeature) -> some View {
        let browse = feature.browsing[config.browseKey]
        let pods = browse?.pods ?? []
        let visible = visiblePods
        if config.context == nil, feature.kubernetes?.isConnected != true {
            StateView(.needsConnection(names: ["Kubernetes"]), action: ("Open Settings", { host.openManager("kubernetes") }))
        } else if let error = browse?.error, browse?.lastSync == nil {
            StateView(.failed(message: error))
        } else if browse?.lastSync == nil {
            StateView(.loading("Loading pods…"))
        } else {
            PodsContent(
                pods: visible, total: pods.count, warnings: browse?.warnings ?? [:],
                scope: PodsScope(context: contextName(feature), namespace: namespaceLabel(feature), allNamespaces: config.namespace == "*",
                                 filters: config.activeFilters, lastSync: browse?.lastSync, error: browse?.error),
                emptyTitle: pods.isEmpty ? "No pods" : config.activeFilters == ["Problems"] ? "All pods healthy" : "No pods match",
                actions: PodActions(pick: { pick($0) }, details: { opened = $0 }, context: contextName(feature)))
        }
    }

    private func contextName(_ feature: PodsFeature) -> String? { config.context ?? feature.cluster?.activeContext }

    private func namespaceLabel(_ feature: PodsFeature) -> String {
        switch config.namespace {
        case nil: feature.defaultNamespace(context: config.context)
        case "*": "all namespaces"
        case let name?: name
        }
    }
}
