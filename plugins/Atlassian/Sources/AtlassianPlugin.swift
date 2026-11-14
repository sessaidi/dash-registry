import DashKit
import Foundation

/// Entry point of Atlassian.dashplugin (matches NSPrincipalClass in Info.plist).
@objc(AtlassianDashPlugin)
final class AtlassianPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [AtlassianIntegration()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { AtlassianPlugin.makeExtensions() }
}
