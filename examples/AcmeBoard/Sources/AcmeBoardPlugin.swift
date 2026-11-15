import DashKit

/// The extensions this plugin adds; Dash gets them through `dash_plugin_entry`.
enum AcmeBoardPlugin {
    @MainActor static func makeExtensions() -> [any DashExtension] { [AcmeBoardFeature()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { AcmeBoardPlugin.makeExtensions() }
}
