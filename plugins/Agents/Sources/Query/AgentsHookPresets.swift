import DashKit
import Foundation

/// Ready-made hooks on this extension's DashQL data (DashKit's library, one set per dataset it
/// offers), shown in Settings › Automation › Hooks.
extension AgentsExtension {
    var hookPresets: [HookPresetSpec] { HookPresetLibrary.presets(for: self) }
}
