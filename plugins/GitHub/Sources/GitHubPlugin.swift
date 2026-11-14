import DashKit
import Foundation

/// Principal class of GitHubPlugin.dashplugin (`NSPrincipalClass` = GitHubDashPlugin).
@objc(GitHubDashPlugin)
final class GitHubPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [GitHubIntegration()] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { GitHubPlugin.makeExtensions() }
}
