import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help workspace` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension WorkspacesFeature {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("workspace", "list", tool: "workspaces_list", summary: "Workspaces (mine=true for yours)."),
            DashQLVerb("workspace", "status", tool: "workspace_status", arguments: ["name"], summary: "A workspace's status."),
            DashQLVerb("workspace", "branch", tool: "workspaces_for_branch", arguments: ["branch"], summary: "Workspaces for a branch, across envs."),
            DashQLVerb("workspace", "pods", tool: "workspace_pods", arguments: ["name"], summary: "Its pods (app=)."),
            DashQLVerb("workspace", "logs", tool: "workspace_logs", arguments: ["name", "pod"], summary: "A pod's logs."),
            DashQLVerb("workspace", "cloudlogs", tool: "workspace_cloud_logs", arguments: ["name"], summary: "Cloud Logging for it (text=, since=)."),
            DashQLVerb("workspace", "events", tool: "workspace_events", arguments: ["name"], summary: "Kubernetes events."),
            DashQLVerb("workspace", "diagnose", tool: "workspace_diagnose", arguments: ["name"], summary: "What's wrong, with findings."),
            DashQLVerb("workspace", "config", tool: "workspace_config", arguments: ["name"], summary: "Its configuration."),
            DashQLVerb("workspace", "train", tool: "workspace_train", summary: "Deployments over time (name=)."),
            DashQLVerb("workspace", "clean", tool: "workspaces_clean_candidates", summary: "Workspaces the cleanup would remove."),
            DashQLVerb("workspace", "create", tool: "workspace_create", arguments: ["name"], summary: "Create one (asks first)."),
            DashQLVerb("workspace", "deploy", tool: "workspace_deploy_worktree", arguments: ["name"], summary: "Build and deploy its worktree (asks first)."),
            DashQLVerb("workspace", "restart", tool: "workspace_restart", arguments: ["name", "app"], summary: "Restart an app (asks first)."),
            DashQLVerb("workspace", "persist", tool: "workspace_set_persist", arguments: ["name"], presets: ["persist": true], summary: "Keep it from cleanup (asks first)."),
            DashQLVerb("workspace", "unpersist", tool: "workspace_set_persist", arguments: ["name"], presets: ["persist": false], summary: "Let cleanup remove it (asks first)."),
        ]
    }
}
