import DashKit
import Foundation

/// Entry point of Docker.dashplugin: the `docker` integration and the Containers feature.
@objc(DockerDashPlugin)
final class DockerPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] {
        [DockerIntegration(), DockerContainersFeature()]
    }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { DockerPlugin.makeExtensions() }
}
