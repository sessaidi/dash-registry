import DashKit
import Foundation

/// The extensions this plugin adds; Dash gets them through `dash_plugin_entry`.
enum ReleasesPlugin {
    @MainActor static func makeExtensions() -> [any DashExtension] { [ReleasesFeature()] }
}

/// The entry point Dash loads: hands over this plugin's integrations and features.
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { ReleasesPlugin.makeExtensions() }
}
