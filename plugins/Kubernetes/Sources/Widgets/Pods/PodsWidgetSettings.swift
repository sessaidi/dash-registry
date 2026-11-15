import DashKit
import SwiftUI

/// The widget's settings: what it shows and how often it refreshes.
struct PodsWidgetSettings: View {
    let feature: PodsFeature?
    @Binding var config: PodsWidget.Config

    var body: some View {
        let contexts = feature?.cluster?.contextNames ?? []
        let namespaces = feature?.namespaces[config.context ?? ""] ?? []
        Section("Source") {
            Picker("Context", selection: $config.context) {
                Text("Same as Kubernetes settings (\(feature?.cluster?.activeContext ?? "none"))").tag(String?.none)
                ForEach(contexts, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            Picker("Namespace", selection: $config.namespace) {
                Text("Context's own (\(feature?.defaultNamespace(context: config.context) ?? "default"))").tag(String?.none)
                Text("All namespaces").tag(String?.some("*"))
                ForEach(namespaces, id: \.self) { Text($0).tag(String?.some($0)) }
                if let current = config.namespace, current != "*", !namespaces.contains(current) { Text(current).tag(String?.some(current)) }
            }
            .task(id: config.context) { await feature?.loadNamespaces(context: config.context) }
            TextField("Label selector", text: text(\.labelSelector), prompt: Text("app=web,tier!=cache"))
            Picker("Refresh", selection: Binding(get: { config.refreshInterval }, set: { config.refresh = $0 })) {
                ForEach([10, 30, 60, 120, 300, 900], id: \.self) { seconds in
                    Text(seconds < 60 ? "Every \(seconds) seconds" : "Every \(seconds / 60) minute\(seconds == 60 ? "" : "s")").tag(seconds)
                }
            }
        }
        Section("Filters") {
            Picker("Status", selection: Binding(get: { config.statusFilter }, set: {
                config.filter = $0.rawValue
                config.problemsOnly = $0 == .problems
            })) {
                ForEach(PodSummary.Filter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Events", selection: $config.event) {
                Text("Any").tag(String?.none)
                Text("Has warning events").tag(String?.some("any"))
                Divider()
                ForEach(PodQuery.eventReasons, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .help("Warning events from the last hour")
            Picker("Controller", selection: $config.controller) {
                Text("Any").tag(String?.none)
                ForEach(PodQuery.controllers, id: \.self) { Text($0 == "none" ? "None (bare pods)" : $0).tag(String?.some($0)) }
            }
            Picker("Restarts", selection: $config.minRestarts) {
                Text("Any").tag(Int?.none)
                ForEach([1, 3, 5, 10], id: \.self) { Text("At least \($0)").tag(Int?.some($0)) }
            }
            Picker("Age", selection: $config.maxAge) {
                Text("Any").tag(Int?.none)
                ForEach([600, 3600, 6 * 3600, 86400, 7 * 86400], id: \.self) { seconds in
                    Text("Younger than \(PodSummary.age(since: Date(timeIntervalSinceNow: -TimeInterval(seconds))))").tag(Int?.some(seconds))
                }
            }
            TextField("Node", text: text(\.node), prompt: Text("part of the node name"))
            TextField("Search", text: text(\.search), prompt: Text("name, IP, app=web, !Running"))
            Picker("Sort by", selection: Binding(get: { config.podSort }, set: { config.sort = $0.rawValue })) {
                ForEach(PodSummary.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    private func text(_ path: WritableKeyPath<PodsWidget.Config, String?>) -> Binding<String> {
        Binding(get: { config[keyPath: path] ?? "" }, set: { config[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
}
