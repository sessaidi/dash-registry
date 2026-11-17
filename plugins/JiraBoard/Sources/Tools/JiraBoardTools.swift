import DashKit
import Foundation
import SwiftData

/// What Dashii can do with Jira issues: list Dash's copy, read and search what the Atlassian
/// integration fetched, follow. Commenting and moving are the user's (approval, remote).
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
                description: "List the Jira issues Dash keeps in sync from the user's board and the issues they follow, with when they were synced. Use this for questions like \"what's on my plate\" or \"what's in review\".",
                properties: [
                    "scope": JSONSchema.string("Which issues: board, followed, or all (default).", enum: ["board", "followed", "all"]),
                    "status": JSONSchema.string("Optional status name filter, e.g. \"In Progress\"."),
                ]
            ) { [weak self] input in
                guard let self, let host else { return [] }
                let request = try input.toolInput(ListInput.self)
                let issues = (try? host.context.fetch(FetchDescriptor<JiraIssue>(sortBy: [SortDescriptor(\.updated, order: .reverse)]))) ?? []
                let syncedAt: JSONValue = lastSync.map { .string($0.formatted(.iso8601)) } ?? .null
                return .array(issues.filter { issue in
                    switch request.scope {
                    case "board": issue.onBoard
                    case "followed": issue.followed
                    default: true
                    }
                }.filter { request.status == nil || $0.statusName.localizedCaseInsensitiveCompare(request.status!) == .orderedSame }
                    .map { $0.json.merging(["synced_at": syncedAt]) })
            },
            DashiiTool(
                name: "jira_follow",
                description: "Follow or unfollow a Jira ticket in Dash (local only; nothing changes in Jira). Followed tickets sync into Dash's copy in the background and show on the Jira Board widget.",
                properties: ["key": JSONSchema.string("Issue key, e.g. KAN-1234."),
                             "follow": JSONSchema.boolean("true to follow (default), false to unfollow.")],
                required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                let request = try input.toolInput(FollowInput.self)
                let key = request.key.uppercased()
                guard Self.isIssueKey(key) else { throw ToolError("\(request.key) is not an issue key.") }
                setFollowed(key, request.follow ?? true)
                syncInBackground()
                return ["key": .string(key), "following": .bool(followedKeys.contains(key))]
            },
            DashiiTool(
                name: "jira_get_issue",
                description: "One Jira issue as Dash fetched it (data_fetch jira.issue), with its description, links and latest comments, synced_at and stale.",
                properties: ["key": JSONSchema.string("Issue key, e.g. KAN-1234.")], required: ["key"]
            ) { [weak self] input in
                guard let self else { return nil }
                let key = try input.toolInput(KeyInput.self).key.uppercased()
                return try await readThroughAtlassian("jira_issue", fetcher: "jira.issue", ["key": .string(key)])
            },
            DashiiTool(
                name: "jira_search",
                description: "Jira issues matching a JQL query as Dash fetched them (data_fetch jira.search, up to 50), with synced_at and stale.",
                properties: ["jql": JSONSchema.string("JQL query.")], required: ["jql"]
            ) { [weak self] input in
                guard let self else { return nil }
                let jql = try input.toolInput(SearchInput.self).jql
                return try await readThroughAtlassian("jira_jql_search", fetcher: "jira.search", ["jql": .string(jql), "limit": 50])
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

    /// Runs the Atlassian integration's reader: Jira data has one store and one fetcher, the
    /// integration's. An Atlassian plugin from before fetch-then-read would read Jira live, so it's refused.
    private func readThroughAtlassian(_ reader: String, fetcher: String, _ input: JSONValue) async throws -> JSONValue {
        guard let atlassian else { throw ToolError("The Atlassian integration is not installed.") }
        guard host?.fetchers.contains(where: { $0.name == fetcher }) == true, let tool = atlassian.tools.first(where: { $0.name == reader }) else {
            throw ToolError("Update the Atlassian plugin (1.7 or later) to read Jira issues from Dash.")
        }
        return try await tool.run(input)
    }
}
