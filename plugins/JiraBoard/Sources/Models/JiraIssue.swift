import DashKit
import Foundation
import SwiftData

/// Same entity name and attributes as the built-in feature's model, so existing stores keep their issues.
@Model
final class JiraIssue {
    @Attribute(.unique) var key: String
    var summary: String
    var statusID: String
    var statusName: String
    var statusCategory: String
    var assignee: String?
    var priority: String?
    var issueType: String?
    var updated: Date?
    var labels: [String]
    /// On the configured board (active sprint for scrum boards).
    var onBoard: Bool
    /// Matched the "following" JQL (assigned to or watched by you, by default), or followed by key.
    var followed: Bool
    /// The followed boards it's on.
    var boardIDs: [Int] = []
    /// Followed one by one (by key), not through the JQL.
    var pinned: Bool = false
    var url: String

    init(_ issue: JiraClient.Issue, url: URL) {
        key = issue.key
        summary = issue.summary
        statusID = issue.statusID
        statusName = issue.statusName
        statusCategory = issue.statusCategory
        assignee = issue.assignee
        priority = issue.priority
        issueType = issue.issueType
        updated = issue.updated
        labels = issue.labels
        onBoard = false
        followed = false
        self.url = url.absoluteString
    }

    func apply(_ issue: JiraClient.Issue) {
        if summary != issue.summary { summary = issue.summary }
        if statusID != issue.statusID { statusID = issue.statusID }
        if statusName != issue.statusName { statusName = issue.statusName }
        if statusCategory != issue.statusCategory { statusCategory = issue.statusCategory }
        if assignee != issue.assignee { assignee = issue.assignee }
        if priority != issue.priority { priority = issue.priority }
        if issueType != issue.issueType { issueType = issue.issueType }
        if updated != issue.updated { updated = issue.updated }
        if labels != issue.labels { labels = issue.labels }
    }

    var json: JSONValue {
        ["key": .string(key), "summary": .string(summary), "status": .string(statusName),
         "statusCategory": .string(statusCategory), "assignee": .string(assignee ?? "Unassigned"),
         "priority": .string(priority ?? ""), "type": .string(issueType ?? ""),
         "updated": .string(updated?.formatted(.iso8601) ?? ""), "onBoard": .bool(onBoard), "followed": .bool(followed)]
    }
}
