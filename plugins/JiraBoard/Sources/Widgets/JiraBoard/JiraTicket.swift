import DashKit
import Foundation

/// What the board draws for one issue: a value copy of `JiraIssue`, so previews can use sample data.
struct JiraTicket: Identifiable, Hashable, Sendable {
    let key: String
    let summary: String
    let statusID: String
    let statusName: String
    let statusCategory: String
    let assignee: String?
    let onBoard: Bool
    let followed: Bool
    let url: String
    var boardIDs: [Int] = []

    var id: String { key }

    init(key: String, summary: String, statusID: String, statusName: String, statusCategory: String,
         assignee: String?, onBoard: Bool, followed: Bool, url: String) {
        self.key = key
        self.summary = summary
        self.statusID = statusID
        self.statusName = statusName
        self.statusCategory = statusCategory
        self.assignee = assignee
        self.onBoard = onBoard
        self.followed = followed
        self.url = url
    }

    @MainActor
    init(_ issue: JiraIssue) {
        self.init(key: issue.key, summary: issue.summary, statusID: issue.statusID, statusName: issue.statusName,
                  statusCategory: issue.statusCategory, assignee: issue.assignee, onBoard: issue.onBoard,
                  followed: issue.followed, url: issue.url)
        boardIDs = issue.boardIDs
    }

    /// The tickets a widget with `config` shows.
    static func visible(_ tickets: [JiraTicket], config: JiraBoardWidget.Config) -> [JiraTicket] {
        tickets.filter { ticket in
            let shown = config.mode != "board" ? ticket.followed
                : config.board.map { ticket.boardIDs.contains($0) } ?? ticket.onBoard
            return shown && !(config.hideDone && ticket.statusCategory == "done")
        }
    }

    static let samples: [JiraTicket] = [
        sample("WEB-482", "Checkout button stays disabled after editing the shipping address", "1", "To Do", "new", "Maya Chen", followed: true),
        sample("WEB-479", "Add rate limiting to the password reset endpoint", "1", "To Do", "new", nil),
        sample("WEB-475", "Migrate order history to the paginated orders API", "3", "In Progress", "indeterminate", "Sam Ortiz", followed: true),
        sample("WEB-471", "Flaky snapshot test in the invoice PDF renderer", "3", "In Progress", "indeterminate", "Priya Natarajan"),
        sample("WEB-466", "Dark mode colours for the account settings page", "10002", "Code Review", "indeterminate", "Maya Chen", followed: true),
        sample("WEB-460", "Upgrade the image CDN client to v4", "10001", "Done", "done", "Leo Martin"),
        sample("OPS-212", "Rotate the staging database credentials", "3", "In Progress", "indeterminate", "Maya Chen", onBoard: false, followed: true),
    ]

    private static func sample(_ key: String, _ summary: String, _ statusID: String, _ statusName: String, _ category: String,
                               _ assignee: String?, onBoard: Bool = true, followed: Bool = false) -> JiraTicket {
        JiraTicket(key: key, summary: summary, statusID: statusID, statusName: statusName, statusCategory: category,
                   assignee: assignee, onBoard: onBoard, followed: followed, url: "https://example.atlassian.net/browse/\(key)")
    }
}

extension JiraClient.Column {
    static let samples = [
        JiraClient.Column(name: "To Do", statusIDs: ["1"]),
        JiraClient.Column(name: "In Progress", statusIDs: ["3"]),
        JiraClient.Column(name: "Review", statusIDs: ["10002"]),
        JiraClient.Column(name: "Done", statusIDs: ["10001"]),
    ]
}
