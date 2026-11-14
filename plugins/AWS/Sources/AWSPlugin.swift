import DashKit
import Foundation

/// Principal class of AWSPlugin.dashplugin (`NSPrincipalClass` = AWSDashPlugin).
@objc(AWSDashPlugin)
final class AWSPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [AWSIntegration()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { AWSPlugin.makeExtensions() }
}
