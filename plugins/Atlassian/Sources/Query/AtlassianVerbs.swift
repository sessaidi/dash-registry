import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help confluence` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension AtlassianIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("confluence", "search", tool: "confluence_search", arguments: ["query"], summary: "Search Confluence pages."),
            DashQLVerb("confluence", "page", tool: "confluence_get_page", arguments: ["id"], summary: "A page in full."),
            DashQLVerb("confluence", "children", tool: "confluence_page_children", arguments: ["id"], summary: "A page's child pages."),
            DashQLVerb("confluence", "spaces", tool: "confluence_spaces", summary: "Confluence spaces."),
            DashQLVerb("issue", "mine", tool: "jira_myself_issues", summary: "Jira issues assigned to me."),
            DashQLVerb("issue", "show", tool: "jira_issue", arguments: ["key"], summary: "A Jira issue."),
            DashQLVerb("issue", "comments", tool: "jira_issue_comments", arguments: ["key"], summary: "An issue's comments."),
            DashQLVerb("issue", "history", tool: "jira_issue_changelog", arguments: ["key"], summary: "An issue's changelog."),
            DashQLVerb("issue", "jql", tool: "jira_jql_search", arguments: ["jql"], summary: "Search Jira with JQL."),
        ]
    }
}
