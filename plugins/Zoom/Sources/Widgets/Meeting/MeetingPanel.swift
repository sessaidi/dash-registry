import DashKit
import DashKitUI
import SwiftData
import SwiftUI

/// The widget body: recording controls, live transcript while in a meeting, past meetings otherwise.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if zoom?.isRecording == true {
                    RecordingLabel(saving: zoom?.saveAudio == true)
                } else {
                    Text(zoom?.inMeeting == true ? "In a Zoom meeting" : zoom?.isZoomRunning == true ? "Zoom is open" : "Zoom is not running")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let zoom, zoom.saveAudio {
                    // Applies to the next recording: the capture's video is set when it starts.
                    Toggle(isOn: Binding(get: { zoom.recordVideo }, set: { zoom.recordVideo = $0 })) {
                        Image(systemName: zoom.recordVideo ? "video.fill" : "video.slash")
                    }
                    .toggleStyle(.button)
                    .help(zoom.recordVideo ? "Video on: Zoom's windows are recorded too" : "Video off: audio only")
                    .disabled(zoom.isRecording)
                }
                if zoom?.isRecording == true {
                    Button("Stop") { Task { await zoom?.stopRecording() } }
                } else {
                    Button(zoom?.saveAudio == true ? "Record" : "Transcribe") { Task { await zoom?.startRecording() } }
                        .disabled(zoom?.isZoomRunning != true)
                }
            }
            if let error = zoom?.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            if zoom?.inMeeting == true, let participants = zoom?.participants, !participants.isEmpty {
                ParticipantChips(names: participants)
            }
            if let meetingID = zoom?.currentMeetingID {
                LiveTranscript(meetingID: meetingID)
            } else if meetings.isEmpty {
                ContentUnavailableView("No meetings yet", systemImage: "waveform", description: Text("Join a Zoom meeting and press Transcribe."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                QueryCount(shown: listed.count, total: meetings.count, query: queryText)
                List(listed) { meeting in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title).lineLimit(1)
                        Text(meeting.summary.isEmpty ? meeting.startedAt.formatted(date: .abbreviated, time: .shortened) : meeting.summary)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .contentShape(.rect)
                    .onTapGesture { selected = meeting }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $selected) { MeetingSheet(meeting: $0, zoom: zoom, host: host) }
        .task(id: QueryRows.key(queryText, meetings, row: \.queryRow)) {
            queryIDs = await QueryRows.ids(query, meetings, row: \.queryRow)
        }
    }
}
