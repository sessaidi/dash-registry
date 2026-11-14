import DashKit
import Foundation

/// Entry point of Workspaces.dashplugin: the backend-workspaces feature, built on the `gcp` integration.
@objc(WorkspacesDashPlugin)
final class WorkspacesPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [WorkspacesFeature()] }
}

/// C entry point Dash loads (Bundle can't resolve NSPrincipalClass for subclasses of DashKit's resilient class).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { WorkspacesPlugin.makeExtensions() }
}
