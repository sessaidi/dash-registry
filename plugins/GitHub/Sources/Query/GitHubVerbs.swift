import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help repo` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension GitHubIntegration {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("repo", "show", tool: "github_repo", arguments: ["repo"], summary: "A repository."),
            DashQLVerb("repo", "branches", tool: "github_branches", arguments: ["repo"], summary: "Branches."),
            DashQLVerb("repo", "commits", tool: "github_commits", arguments: ["repo"], summary: "Commits (branch=, path=, author=)."),
            DashQLVerb("repo", "pulls", tool: "github_pulls", arguments: ["repo"], summary: "Pull requests."),
            DashQLVerb("repo", "issues", tool: "github_issues", arguments: ["repo"], summary: "Issues."),
            DashQLVerb("repo", "releases", tool: "github_releases", arguments: ["repo"], summary: "Releases."),
            DashQLVerb("repo", "compare", tool: "github_compare", arguments: ["repo", "base", "head"], summary: "Commits between two refs."),
            DashQLVerb("repo", "file", tool: "github_file", arguments: ["repo", "path"], summary: "A file (ref=)."),
            DashQLVerb("ci", "runs", tool: "github_workflow_runs", arguments: ["repo"], summary: "Workflow runs (branch=, status=)."),
            DashQLVerb("ci", "jobs", tool: "github_run_jobs", arguments: ["repo", "run_id"], summary: "A run's jobs."),
            DashQLVerb("ci", "log", tool: "github_job_log", arguments: ["repo", "job_id"], summary: "A job's log."),
            DashQLVerb("ci", "checks", tool: "github_checks", arguments: ["repo", "ref"], summary: "Checks on a ref."),
            DashQLVerb("github", "search", tool: "github_search", arguments: ["kind", "query"], summary: "Search code, issues or repos."),
            DashQLVerb("github", "notifications", tool: "github_notifications", summary: "Your notifications."),
        ]
    }
}
