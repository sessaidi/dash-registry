import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help session` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension AgentsExtension {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("session", "list", tool: "agents_list", summary: "Agent sessions on Jira tickets."),
            DashQLVerb("session", "start", tool: "agents_start", arguments: ["issue_key"], summary: "Start an agent session on a ticket (asks first)."),
            DashQLVerb("session", "read", tool: "agents_read", arguments: ["session_id"], summary: "A session's latest messages."),
            DashQLVerb("session", "send", tool: "agents_send", arguments: ["session_id", "message"], summary: "Send a message to a session (asks first)."),
            DashQLVerb("session", "open", tool: "agents_open", arguments: ["session_id"], summary: "Open a session in Dash."),
        ]
    }
}
