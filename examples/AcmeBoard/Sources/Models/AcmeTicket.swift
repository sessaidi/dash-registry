import DashKit
import Foundation

/// One Acme ticket as the feature keeps it: plain data, so views, previews and tests need no
/// service. Read from the `acme` integration's JSON (features never import an integration's types).
struct AcmeTicket: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// todo, doing or done.
    let status: String
    /// low, normal, high or urgent.
    let priority: String
    let assignee: String?

    init(id: String, title: String, status: String, priority: String, assignee: String?) {
        self.id = id
        self.title = title
        self.status = status
        self.priority = priority
        self.assignee = assignee
    }

    init(json: JSONValue) {
        self.init(id: json["id"]?.string ?? "", title: json["title"]?.string ?? "", status: json["status"]?.string ?? "todo",
                  priority: json["priority"]?.string ?? "normal", assignee: json["assignee"]?.string)
    }

    var isUrgent: Bool { priority == "urgent" && status != "done" }
    /// Open and urgent or high: what the triage agent looks at.
    var needsTriage: Bool { (priority == "urgent" || priority == "high") && status != "done" }

    var json: JSONValue {
        ["id": .string(id), "title": .string(title), "status": .string(status), "priority": .string(priority),
         "assignee": assignee.map { .string($0) } ?? .null]
    }

    static let samples = [
        AcmeTicket(id: "ACME-12", title: "Checkout fails for EU cards", status: "doing", priority: "urgent", assignee: "Ada"),
        AcmeTicket(id: "ACME-15", title: "Add dark mode to settings", status: "todo", priority: "normal", assignee: nil),
        AcmeTicket(id: "ACME-9", title: "Retry webhooks with backoff", status: "doing", priority: "high", assignee: "Sam"),
        AcmeTicket(id: "ACME-17", title: "Typo on the pricing page", status: "todo", priority: "low", assignee: "Lin"),
        AcmeTicket(id: "ACME-4", title: "Rotate staging credentials", status: "done", priority: "high", assignee: "Ada"),
    ]
}
