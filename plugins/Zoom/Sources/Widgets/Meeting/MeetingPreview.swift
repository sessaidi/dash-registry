import SwiftUI

/// The widget gallery's picture: the same responsive layout over `MeetingSample`, a meeting
/// being transcribed (the past meetings show where there's room for them).
struct MeetingPreview: View {
    var body: some View {
        MeetingLayout(
            live: MeetingLive(zoomRunning: true, inMeeting: true, recording: true, participants: MeetingSample.participants,
                              meetingID: UUID(), title: MeetingSample.title, startedAt: MeetingSample.startedAt),
            lines: MeetingSample.lines, past: MeetingSample.past, total: MeetingSample.past.count)
        .allowsHitTesting(false)
    }
}
