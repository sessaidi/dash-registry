import DashKit

/// Acme Board's agents. Dash runs them with Dashii on their schedule, when one of their events
/// happens, or when Dashii hands them a question (`agent acme-board.triage ask "…"`).
enum AcmeAgents {
    static let triage = AgentDefinition(
        id: "triage", name: "Ticket triage", summary: "Looks at urgent and high Acme tickets and says what to do first; read-only.",
        systemImage: "stethoscope", role: "support lead",
        specialities: ["ticket triage", "prioritisation"],
        instructions: """
            Look at the open Acme tickets with `acme_board_tickets`. For each urgent or high ticket: is someone on it, \
            is it blocked, what should happen next. Rank them. Use `acme_board_summarize` for a quick overview.
            In the report: the summary says what to do first; one finding per ticket that needs attention, critical \
            for urgent and unassigned, warning for urgent or high, info otherwise.
            """,
        // Only the two tools it needs: not `integrations: ["acme"]`, which would also give it
        // `acme_get` (any API path with the user's token).
        tools: ["acme_board_tickets", "acme_board_summarize"],
        access: .readOnly,
        scope: "Acme tickets only; advise, never change a ticket.",
        schedule: AgentSchedule(everyMinutes: 60, events: ["acme.urgent"]),
        models: [.balanced, .fast, .strong], defaultModel: .balanced,
        // Free check before any token is spent: nothing urgent or high, nothing to triage.
        precheck: { host in
            let open = host.ext(AcmeBoardFeature.self)?.tickets.filter(\.needsTriage) ?? []
            return open.isEmpty ? .skip("No urgent or high ticket.")
                : .run(context: "Open now: " + open.map { "\($0.id) \($0.priority) \($0.title) (\($0.assignee ?? "unassigned"))" }.joined(separator: "; "))
        })
}
