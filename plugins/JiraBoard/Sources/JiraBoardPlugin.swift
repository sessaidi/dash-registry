import DashKit
import Foundation

/// Principal class of JiraBoardPlugin.dashplugin (`NSPrincipalClass` = JiraBoardDashPlugin).
/// The feature needs the `atlassian` integration, which ships as its own plugin.
@objc(JiraBoardDashPlugin)
final class JiraBoardPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [JiraBoardFeature()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { JiraBoardPlugin.makeExtensions() }
}
