import DashKit
import Foundation

/// Principal class of PullRequestsPlugin.dashplugin (`NSPrincipalClass` = PullRequestsDashPlugin).
@objc(PullRequestsDashPlugin)
final class PullRequestsPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [PullRequestsFeature()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { PullRequestsPlugin.makeExtensions() }
}
