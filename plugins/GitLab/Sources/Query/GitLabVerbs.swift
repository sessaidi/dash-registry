import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help mr` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension GitLabIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("mr", "list", tool: "gitlab_merge_requests", summary: "GitLab merge requests (project=, scope=)."),
            DashQLVerb("gitlab", "get", tool: "gitlab_api_read", arguments: ["path"], summary: "A GitLab API answer Dash fetched (data_fetch gitlab.api)."),
        ]
    }
}
