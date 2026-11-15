import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help backend` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension BackendMeetingFeature {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("backend", "reports", tool: "backend_meeting_reports", summary: "Backend Meeting reports."),
        ]
    }
}
