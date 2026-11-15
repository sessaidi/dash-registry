import DashKit

/// Acme Board in DashQL (`from acme_tickets where priority = "urgent"`, `acme summarize`) and a
/// ready-made hook.
extension AcmeBoardFeature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "acme_tickets", aliases: ["acme"], summary: "Acme tickets.",
                      fields: [.init("id", .string, "Ticket id"), .init("title", .string, "Title"),
                               .init("status", .string, "todo, doing or done"), .init("priority", .string, "low, normal, high or urgent"),
                               .init("assignee", .string, "Who works on it")]) { [weak self] _ in
            (self?.tickets ?? []).map(\.json)
        }]
    }

    var verbs: [DashQLVerb] {
        [DashQLVerb("acme", "tickets", tool: "acme_board_tickets", summary: "List the tickets."),
         DashQLVerb("acme", "summarize", tool: "acme_board_summarize", summary: "Summarize the open tickets.")]
    }

    var hookPresets: [HookPresetSpec] {
        [.appears("acme-board.urgent", "New urgent Acme ticket", dataset: "acme_tickets", where: "priority = \"urgent\" and status != \"done\"", key: "id",
                  title: "Urgent: {{first.title}}", body: "{{first.id}}")]
    }
}
