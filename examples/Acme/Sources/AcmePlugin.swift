import DashKit

/// The extensions this plugin adds; Dash gets them through `dash_plugin_entry`.
enum AcmePlugin {
    @MainActor static func makeExtensions() -> [any DashExtension] { [AcmeIntegration()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { AcmePlugin.makeExtensions() }
}
