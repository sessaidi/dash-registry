import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help standup` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension DailyStandupFeature {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("standup", "today", tool: "standup_today", summary: "Today's standup."),
            DashQLVerb("standup", "prepare", tool: "standup_prepare", summary: "Prepare today's update."),
            DashQLVerb("standup", "blockers", tool: "standup_blockers", summary: "Open blockers."),
            DashQLVerb("standup", "history", tool: "standup_history", arguments: ["date"], summary: "A past day's standup."),
        ]
    }
}
