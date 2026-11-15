import DashKit
import DashKitUI
import SwiftUI

/// How long reads are reused, what's cached, and a way to forget it.
struct AtlassianCacheSection: View {
    @Bindable var atlassian: AtlassianIntegration
    @State private var counts: [String: Int] = [:]

    var body: some View {
        Section {
            Picker("Reuse a page or issue for", selection: $atlassian.cacheMinutes) {
                ForEach([5, 15, 30, 60, 240, 1440], id: \.self) { minutes in
                    Text(minutes < 60 ? "\(minutes) min" : minutes == 1440 ? "1 day" : "\(minutes / 60) h").tag(minutes)
                }
            }
            let stored = AtlassianIntegration.cacheKinds.filter { (counts[$0.kind] ?? 0) > 0 }
            if stored.isEmpty {
                Text("Nothing cached yet.").foregroundStyle(.secondary)
            } else {
                ForEach(stored, id: \.kind) { item in
                    LabeledContent(item.label) { Text("\(counts[item.kind] ?? 0)").monospacedDigit() }
                }
            }
            Button("Clear Cached Confluence and Jira Data", role: .destructive) {
                atlassian.clearCache()
                reload()
            }
            .disabled(stored.isEmpty)
        } header: {
            Text("Cache")
        } footer: {
            Text("Only what Dashii asked for is kept, in Dash's database, with secrets removed. Jira and Confluence stay the source of truth: older copies are read again online, and a cached copy is used only when the site can't be reached.")
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        counts = Dictionary(uniqueKeysWithValues: AtlassianIntegration.cacheKinds.map { ($0.kind, atlassian.cachedCount($0.kind)) })
    }
}
