import DashKit
import Foundation

/// Principal class of AgentsPlugin.dashplugin (`NSPrincipalClass` = AgentsDashPlugin).
@objc(AgentsDashPlugin)
final class AgentsPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [AgentsExtension()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { AgentsPlugin.makeExtensions() }
}
