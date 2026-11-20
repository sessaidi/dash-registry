import DashKit
import Foundation
import Ingestor

/// The extensions this plugin adds; Dash gets them through `dash_plugin_entry`.
enum GitHubPlugin {
    @MainActor static func makeExtensions() -> [any DashExtension] { [GitHubIntegration(databaseFolder: IngestDatabase.folder)] }
}

/// The C entry point Dash loads (see docs/PLUGINS.md).
@_cdecl("dash_plugin_entry")
public func dashPluginEntry() -> UnsafeMutableRawPointer {
    DashPluginFactory.export { GitHubPlugin.makeExtensions() }
}
