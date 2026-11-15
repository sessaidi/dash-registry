import DashKit
import Foundation
import SwiftData

/// What Dashii can do with Jira issues: list, read, search, comment, move, follow.
extension JiraBoardFeature {
    private struct KeyInput: Decodable { let key: String }
    private struct ListInput: Decodable { let scope: String?; let status: String? }
    private struct CommentInput: Decodable { let key: String; let text: String }
    private struct TransitionInput: Decodable { let key: String; let status: String }
    private struct SearchInput: Decodable { let jql: String }
    private struct FollowInput: Decodable { let key: String; let follow: Bool? }

    var tools: [DashiiTool] {
        [
            DashiiTool(
                name: "jira_list_issues",
                description: "List cached Jira issues from the user's board and the issues they follow. Use this for questions like \"what's on my plate\" or \"what's in review\".",
                properties: [
                    "scope": JSONSchema.string("Which issues: board, followed, or all (default).", enum: ["board", "followed", "all"]),
                    "status": JSONSchema.string("Optional status name filter, e.g. \"In Progress\"."),
                ]
            ) { [weak self] input in
                guard let self, let host else { return [] }
                let request = try input.toolInput(ListInput.self)
                let issues = (try? host.context.fetch(FetchDescriptor<JiraIssue>(sortBy: [SortDescriptor(\.updated, order: .reverse)]))) ?? []
                return .array(issues.filter { issue in
                    switch request.scope {
                    case "board": issue.onBoard
                    case "followed": issue.followed
                    default: true
                    }
                }.filter { request.status == nil || $0.statusName.localizedCaseInsensitiveCompare(request.status!) == .orderedSame }.map(\.json))
            },
            DashiiTool(
                name: "jira_follow",
                description: "Follow or unfollow a Jira ticket in Dash (local only; nothing changes in Jira). Followed tickets sync into the cache and show in \"Issues I follow\".",
                properties: ["key": JSONSchema.string("Issue key, e.g. LAF-1234."),
                             "follow": JSONSchema.boolean("true to follow (default), false to unfollow.")],
                required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(FollowInput.self)
                let key = request.key.uppercased()
                guard Self.isIssueKey(key) else { throw ToolError("\(request.key) is not an issue key.") }
                if request.follow ?? true { await follow(key) } else { await unfollow(key) }
                return ["key": .string(key), "following": .bool(followedKeys.contains(key))]
            },
            DashiiTool(
                name: "jira_get_issue",
                description: "Fetch one Jira issue live, with its description and recent comments.",
                properties: ["key": JSONSchema.string("Issue key, e.g. LAF-1234.")], required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                return try await client.issueDetail(input.toolInput(KeyInput.self).key.uppercased())
            },
            DashiiTool(
                name: "jira_search",
                description: "Run a JQL search against Jira (live, up to 50 results).",
                properties: ["jql": JSONSchema.string("JQL query.")], required: ["jql"]
            ) { [weak self] input in
                guard let self else { return nil }
                let issues = try await client.search(input.toolInput(SearchInput.self).jql, limit: 50)
                return .array(issues.prefix(50).map { ["key": .string($0.key), "summary": .string($0.summary), "status": .string($0.statusName), "assignee": .string($0.assignee ?? "Unassigned")] })
            },
            DashiiTool(
                name: "jira_add_comment",
                description: "Post a comment on a Jira issue.",
                properties: ["key": JSONSchema.string("Issue key."), "text": JSONSchema.string("Comment text. Blank lines separate paragraphs.")],
                required: ["key", "text"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(CommentInput.self)
                try await client.comment(request.key, text: request.text)
                return "commented"
            },
            DashiiTool(
                name: "jira_transition_issue",
                description: "Move a Jira issue to another status using one of its workflow transitions (for example \"In Progress\" or \"Code Review\").",
                properties: ["key": JSONSchema.string("Issue key."), "status": JSONSchema.string("Transition or status name.")],
                required: ["key", "status"], requiresApproval: true, writesRemotely: true
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(TransitionInput.self)
                return .string("Moved via \"\(try await move(request.key, toStatus: request.status))\".")
            },
        ]
    }
}
