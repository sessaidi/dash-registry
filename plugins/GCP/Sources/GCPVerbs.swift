import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help gcp` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension GCPIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("gcp", "projects", tool: "gcp_list_projects", summary: "Projects you can read."),
            DashQLVerb("gcp", "clusters", tool: "gcp_gke_clusters", arguments: ["project"], summary: "GKE clusters of a project."),
            DashQLVerb("gcp", "logs", tool: "gcp_logs_query", arguments: ["project"], summary: "Cloud Logging (filter=, namespace=, pod=)."),
            DashQLVerb("gcp", "errors", tool: "gcp_error_groups", arguments: ["project"], summary: "Error Reporting groups."),
            DashQLVerb("gcp", "builds", tool: "gcp_cloud_builds", arguments: ["project"], summary: "Cloud Builds."),
            DashQLVerb("gcp", "run", tool: "gcp_cloud_run_services", arguments: ["project"], summary: "Cloud Run services."),
            DashQLVerb("gcp", "sql", tool: "gcp_sql_instances", arguments: ["project"], summary: "Cloud SQL instances."),
        ]
    }
}
