import DashKit
import Foundation
import Testing

/// The plugin's ready-made hooks: ids prefixed with their extension's id and unique, watch queries valid DashQL.
@MainActor
struct HookPresetsTests {
    @Test func presetsAreWellFormed() throws {
        let extensions = PullRequestsPlugin.makeExtensions()
        let presets = extensions.flatMap { item in item.hookPresets.map { (item.id, $0) } }
        #expect(!presets.isEmpty)
        #expect(Set(presets.map(\.1.id)).count == presets.count)
        for (owner, preset) in presets {
            #expect(preset.id.hasPrefix(owner + "."), "\(preset.id) should start with \(owner).")
            if case .watch(let query, let minutes, _) = preset.trigger {
                #expect(minutes > 0)
                _ = try DashQuery.parse(query)
            }
        }
    }
}
