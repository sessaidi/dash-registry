import DashKit
import Foundation

/// Entry point of GCP.dashplugin (Info.plist `NSPrincipalClass`).
@objc(GCPDashPlugin)
final class GCPPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [GCPIntegration()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { GCPPlugin.makeExtensions() }
}
