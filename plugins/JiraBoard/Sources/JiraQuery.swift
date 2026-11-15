import DashKit
import Foundation
import SwiftData

/// Jira issues for DashQL: the `jira` dataset (Dash's local copy) and the board widget's query bar.
extension JiraIssue {
    static let queryFields: [QueryDataset.Field] = [
        .init("key", "string", "Issue key, e.g. LAF-1234 (joins prs.tickets and agents.issue_key)", aliases: ["ticket", "id"]),
        .init("summary", "string", "Title", aliases: ["title"]),
        .init("status", "string", "Status name, e.g. In Progress"),
        .init("status_category", "string", "new (to do), indeterminate (in progress) or done", aliases: ["category"]),
        .init("assignee", "string", "Assignee's name"),
        .init("priority", "string", "Highest, High, Medium, Low…"),
        .init("type", "string", "Story, Bug, Task…", aliases: ["issue_type"]),
        .init("labels", "list", "Labels"),
        .init("project", "string", "Project key, e.g. LAF"),
        .init("updated", "date", "Last update"),
        .init("followed", "bool", "The user follows it"),
        .init("on_board", "bool", "On a followed board"),
        .init("board_ids", "list", "Followed boards it's on"),
        .init("url", "string", "Browse link"),
    ]

    var queryRow: JSONValue {
        [
            "key": .string(key), "summary": .string(summary), "status": .string(statusName), "status_category": .string(statusCategory),
            "assignee": assignee.queryValue, "priority": priority.queryValue, "type": issueType.queryValue,
            "labels": .array(labels.map(JSONValue.string)), "project": .string(String(key.split(separator: "-").first ?? "")),
            "updated": updated.queryValue, "followed": .bool(followed), "on_board": .bool(onBoard),
            "board_ids": .array(boardIDs.map { .number(Double($0)) }), "url": .string(url),
        ]
    }
}

extension JiraBoardFeature {
    var datasets: [QueryDataset] {
        [QueryDataset(name: "jira", aliases: ["tickets", "issues"], summary: "Jira issues in Dash's local copy: the followed boards' issues and the tickets the user follows.",
                      fields: JiraIssue.queryFields) { [weak self] _ in
            guard let context = self?.host?.context else { return [] }
            let issues = (try? context.fetch(FetchDescriptor<JiraIssue>(sortBy: [SortDescriptor(\.updated, order: .reverse)]))) ?? []
            return issues.map(\.queryRow)
        }]
    }
}
