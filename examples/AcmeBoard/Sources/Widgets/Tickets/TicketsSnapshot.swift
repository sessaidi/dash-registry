/// What the widget shows: plain data, so previews and tests need no services.
struct TicketsSnapshot: Sendable, Equatable {
    var tickets: [AcmeTicket]
    /// The triage agent's last summary, shown in the large layout.
    var triage: String?

    static let statuses = ["todo", "doing", "done"]

    static let sample = TicketsSnapshot(tickets: AcmeTicket.samples,
                                        triage: "One urgent ticket: EU card checkouts fail since this morning's deploy; Ada is on it.")
}
