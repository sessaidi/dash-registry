import DashKit
import Foundation

/// Principal class of ZoomPlugin.dashplugin (`NSPrincipalClass` = ZoomDashPlugin): the Zoom feature.
@objc(ZoomDashPlugin)
final class ZoomPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [ZoomExtension()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { ZoomPlugin.makeExtensions() }
}
