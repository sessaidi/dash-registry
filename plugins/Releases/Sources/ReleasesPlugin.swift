import DashKit
import Foundation

/// The plugin's principal class (informational; Dash calls `dash_plugin_entry`).
@objc(ReleasesDashPlugin)
final class ReleasesPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [ReleasesFeature()] }
}

/// The entry point Dash loads: hands over this plugin's integrations and features.
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { ReleasesPlugin.makeExtensions() }
}
