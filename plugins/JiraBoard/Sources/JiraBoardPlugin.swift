import DashKit
import Foundation

/// The feature needs the `atlassian` integration, which ships as its own plugin.
/// The extensions this plugin adds; Dash gets them through `dash_plugin_entry`.
enum JiraBoardPlugin {
    @MainActor static func makeExtensions() -> [any DashExtension] { [JiraBoardFeature()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { JiraBoardPlugin.makeExtensions() }
}
