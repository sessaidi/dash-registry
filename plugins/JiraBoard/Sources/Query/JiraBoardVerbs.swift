import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help ticket` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension JiraBoardFeature {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("ticket", "list", tool: "jira_list_issues", summary: "Board tickets (scope=, status=)."),
            DashQLVerb("ticket", "show", tool: "jira_get_issue", arguments: ["key"], summary: "A ticket."),
            DashQLVerb("ticket", "search", tool: "jira_search", arguments: ["jql"], summary: "Search with JQL."),
            DashQLVerb("ticket", "follow", tool: "jira_follow", arguments: ["key"], presets: ["follow": true], summary: "Follow a ticket on the board."),
            DashQLVerb("ticket", "unfollow", tool: "jira_follow", arguments: ["key"], presets: ["follow": false], summary: "Stop following a ticket."),
        ]
    }
}
