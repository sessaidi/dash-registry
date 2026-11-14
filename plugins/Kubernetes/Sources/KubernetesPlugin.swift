import DashKit
import Foundation

/// Entry point of Kubernetes.dashplugin: the `kubernetes` integration and the Pods feature.
@objc(KubernetesDashPlugin)
final class KubernetesPlugin: DashPlugin {
    override class func makeExtensions() -> [any DashExtension] { [KubernetesIntegration(), PodsFeature()] }
}

/// C entry point Dash loads (Bundle can't resolve NSPrincipalClass for subclasses of DashKit's resilient class).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { KubernetesPlugin.makeExtensions() }
}
