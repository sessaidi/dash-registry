import AppKit
import DashKit
import SwiftUI

/// One AppKit window per agent session. Plugins can't add SwiftUI scenes to Dash, so the
/// chat lives in an `NSWindow` sharing the host's model context.
@MainActor
final class AgentWindows {
    static let shared = AgentWindows()
    private var windows: [UUID: NSWindow] = [:]

    func open(sessionID: UUID, agents: AgentsExtension, host: any ExtensionContext) {
        if let window = windows[sessionID] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let root = AgentWorkspaceWindow(sessionID: sessionID, agents: agents).modelContext(host.context)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        let session = agents.session(sessionID)
        window.title = session.map { "\($0.issueKey) — \($0.title)" } ?? "Agent"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.setFrameAutosaveName("agent-workspace-\(sessionID.uuidString)")
        windows[sessionID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
