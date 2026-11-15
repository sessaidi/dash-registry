import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help pr` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension PullRequestsFeature {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("pr", "list", tool: "github_list_prs", summary: "Pull requests on watched repos (repo=, filter=)."),
            DashQLVerb("pr", "show", tool: "github_get_pr", arguments: ["repo", "number"], summary: "A pull request."),
            DashQLVerb("pr", "diff", tool: "github_get_diff", arguments: ["repo", "number"], summary: "A pull request's diff."),
            DashQLVerb("pr", "review", tool: "github_rerun_review", arguments: ["repo", "number"], summary: "Run Dashii's review again."),
        ]
    }
}
