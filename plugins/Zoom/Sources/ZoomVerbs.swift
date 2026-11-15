import DashKit

/// What Dashii and agents can write in DashQL for this plugin (`help meeting` lists them).
/// Each statement runs one of the plugin's tools, with the same approvals.
extension ZoomExtension {
    var verbs: [DashQLVerb] {
        [
            DashQLVerb("meeting", "list", tool: "meetings_list", summary: "Transcribed meetings."),
            DashQLVerb("meeting", "transcript", tool: "meeting_transcript", arguments: ["meeting_id"], summary: "A meeting's transcript."),
            DashQLVerb("meeting", "speakers", tool: "meeting_speakers", arguments: ["meeting_id"], summary: "Who spoke and how much."),
            DashQLVerb("meeting", "participants", tool: "meeting_participants", summary: "Participants."),
            DashQLVerb("meeting", "summary", tool: "meeting_summarize", arguments: ["meeting_id"], summary: "Summarize a meeting."),
        ]
    }
}
