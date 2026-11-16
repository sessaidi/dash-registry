import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// The widget body: Zoom's live state, the live transcript and the stored meetings, laid out
/// per size by `MeetingLayout`.
struct MeetingPanel: View {
    let zoom: ZoomExtension?
    let host: any ExtensionContext
    let recentCount: Int
    /// The widget's DashQL query (its query bar): which past meetings to list. Without one, the
    /// most recent `recentCount`.
    let query: WidgetQuery?
    let queryText: String
    @Query(sort: \MeetingRecord.startedAt, order: .reverse) private var meetings: [MeetingRecord]
    @State private var selected: MeetingRecord?
    @State private var queryIDs: [UUID]?

    private var listed: [MeetingRecord] {
        queryIDs == nil ? Array(meetings.prefix(recentCount)) : QueryRows.ordered(meetings, by: queryIDs)
    }

    private var live: MeetingLive {
        guard let zoom else { return MeetingLive() }
        let current = zoom.currentMeetingID.flatMap { id in meetings.first { $0.id == id } }
        return MeetingLive(zoomRunning: zoom.isZoomRunning, inMeeting: zoom.inMeeting, recording: zoom.isRecording, saveAudio: zoom.saveAudio,
                           recordVideo: zoom.recordVideo, summarizing: zoom.isSummarizing, error: zoom.lastError, stopReason: zoom.lastStopReason, participants: zoom.participants,
                           meetingID: zoom.currentMeetingID, title: current?.title, startedAt: current?.startedAt)
    }

    private var commands: MeetingCommands {
        MeetingCommands(
            record: { Task { await zoom?.startRecording() } },
            stop: { Task { await zoom?.stopRecording(reason: "You stopped it.") } },
            setVideo: { zoom?.recordVideo = $0 },
            open: { id in selected = meetings.first { $0.id == id } })
    }

    var body: some View {
        let live = live
        // The meeting being transcribed isn't "past" yet.
        let past = listed.filter { $0.id != live.meetingID }.map(MeetingDigest.init)
        Group {
            if let meetingID = live.meetingID {
                LiveSegments(meetingID: meetingID) { lines in
                    MeetingLayout(live: live, lines: lines, past: past, commands: commands, query: queryText, total: meetings.count)
                }
            } else {
                MeetingLayout(live: live, lines: [], past: past, commands: commands, query: queryText, total: meetings.count)
            }
        }
        .sheet(item: $selected) { MeetingSheet(meeting: $0, zoom: zoom, host: host) }
        .task(id: QueryRows.key(queryText, meetings, row: \.queryRow)) {
            queryIDs = await QueryRows.ids(query, meetings, row: \.queryRow)
        }
    }
}
