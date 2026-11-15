import DashKit
import DashKitUI
import SwiftUI

/// The Agents widget at any size: one layout per size family, over live sessions or the samples.
///
/// - narrow: "2 working · 1 needs you" and the sessions that need a look first.
/// - medium: every session as a row.
/// - wide: a table (ticket, title, state, phase, cost, last activity).
/// - large: a summary strip, the sessions, and the focused session's detail.
struct AgentsLayout: View {
    let rows: [AgentSummary]
    var selectedID: UUID? = nil
    /// Clicking a session: selects and opens it, or unselects it when it's the selected one.
    let open: (UUID) -> Void
    /// Opens a session's chat window without touching the selection; nil in the gallery.
    var openChat: ((UUID) -> Void)? = nil
    /// Starts an agent on a ticket key; nil in the gallery.
    var start: ((String) async throws -> Void)? = nil
    @Environment(\.widgetLayout) private var layout

    var body: some View {
        if rows.isEmpty {
            AgentsEmpty(compact: layout.family == .narrow, start: start)
        } else {
            Group {
                switch layout.family {
                case .narrow: AgentGlance(rows: rows, selectedID: selectedID, open: open, room: layout.size.height)
                case .wide: AgentTable(rows: rows, selectedID: selectedID, open: open)
                case .large: AgentOverview(rows: rows, selectedID: selectedID, open: open, openChat: openChat ?? { _ in })
                default: AgentRows(rows: rows, selectedID: selectedID, open: open)
                }
            }
            .widgetHeader {
                if let start, layout.family != .narrow { StartAgentButton(start: start) }
            }
        }
    }
}

/// No sessions: say so and offer to start one, compactly when narrow.
struct AgentsEmpty: View {
    let compact: Bool
    let start: ((String) async throws -> Void)?

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 6) {
                Label("No agents", systemImage: "hammer").font(.headline)
                Text("Start one on a Jira ticket.").font(.caption).foregroundStyle(.secondary)
                if let start { StartAgentField(start: start) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            ContentUnavailableView {
                Label("No agents", systemImage: "hammer")
            } description: {
                Text("Start one on a Jira ticket: it plans with you, then works in its own worktree.")
            } actions: {
                if let start { StartAgentField(start: start).frame(maxWidth: 320) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A ticket key field and Start Agent.
struct StartAgentField: View {
    let start: (String) async throws -> Void
    @State private var key = ""
    @State private var error: String?

    private var trimmed: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TextField("Ticket", text: $key, prompt: Text("LAF-1234"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                AsyncButton("Start Agent") {
                    try await start(trimmed)
                    key = ""
                    error = nil
                } onError: { error = $0.localizedDescription }
                .buttonStyle(.borderedProminent)
                .disabled(trimmed.isEmpty)
            }
            .controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(3) }
        }
    }
}

/// The header's "+": Start Agent in a popover.
struct StartAgentButton: View {
    let start: (String) async throws -> Void
    @State private var asking = false

    var body: some View {
        Button("Start Agent", systemImage: "plus") { asking = true }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Start an agent on a Jira ticket")
            .popover(isPresented: $asking, arrowEdge: .bottom) {
                StartAgentField(start: { key in
                    try await start(key)
                    asking = false
                })
                .frame(width: 280)
                .padding(12)
            }
    }
}
