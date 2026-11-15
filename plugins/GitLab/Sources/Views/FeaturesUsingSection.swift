import DashKit
import SwiftUI

/// Lists the features built on an integration, for its settings pane. Plugins can't see the
/// app's extension host, so this reads the extensions of the context passed to `start(host:)`.
struct FeaturesUsingSection: View {
    let integrationID: String
    let host: (any ExtensionContext)?

    var body: some View {
        let features = Self.features(using: integrationID, in: host?.extensions ?? [])
        if !features.isEmpty {
            Section("Features using this integration") {
                ForEach(features, id: \.id) { feature in
                    Label(feature.name, systemImage: feature.systemImage)
                }
            }
        }
    }

    /// Extensions that require or optionally use `integrationID`.
    static func features(using integrationID: String, in extensions: [any DashExtension]) -> [any DashExtension] {
        extensions.filter { $0.requires.contains(integrationID) || $0.optional.contains(integrationID) }
    }
}
