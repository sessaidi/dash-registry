import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help release` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension ReleasesFeature {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("release", "list", tool: "releases_list", summary: "Releases (repo=, train=, since=)."),
            DashQLVerb("release", "show", tool: "release_detail", arguments: ["tag"], summary: "A release."),
            DashQLVerb("release", "live", tool: "release_live_at", arguments: ["date"], summary: "What was live at a date."),
            DashQLVerb("release", "containing", tool: "releases_containing", arguments: ["text"], summary: "Releases containing a ticket or commit."),
            DashQLVerb("release", "note", tool: "release_events_add", arguments: ["date", "title"], summary: "Add an event to the timeline (asks first)."),
        ]
    }
}
