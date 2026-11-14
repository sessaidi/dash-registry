import DashKit
import Foundation

/// Principal class of GitLabPlugin.dashplugin (`NSPrincipalClass` = GitLabDashPlugin).
@objc(GitLabDashPlugin)
final class GitLabPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [GitLabIntegration()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { GitLabPlugin.makeExtensions() }
}
