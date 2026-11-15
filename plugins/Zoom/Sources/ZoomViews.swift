import AppKit
import DashKit
import DashKitUI
import SwiftData
import SwiftUI

struct MeetingWidget: DashboardWidget {
    struct Config: Codable, Equatable, Sendable {
        var recentCount: Int
    }

    static let kind = "zoom.meeting"
    static let sizeLimits = GridLimits(minW: 3, minH: 4, maxW: 8, maxH: 20)
    static let displayName = "Meeting"
    static let summary = "Live Zoom transcript and participants while a meeting runs; recent meeting summaries otherwise."
    static let systemImage = "video"
    static let defaultSize = WidgetSize.large
    static let defaultConfig = Config(recentCount: 5)
    static let configSchema: JSONValue = [
        "type": "object",
        "properties": ["recentCount": ["type": "integer", "description": "How many past meetings to list."]],
    ]

    static let queryFields = MeetingRecord.queryFields

    static func content(config: Binding<Config>, context: WidgetContext) -> some View {
        MeetingPanel(zoom: context.host.ext(ZoomExtension.self), host: context.host, recentCount: config.wrappedValue.recentCount,
                     query: context.query(fields: MeetingRecord.queryFields), queryText: context.queryText)
    }

    static func preview(config: Config) -> some View {
        MeetingPreview()
    }

    static func snapshot(config: Config, context: WidgetContext) async -> JSONValue {
        guard let zoom = context.host.ext(ZoomExtension.self) else { return .null }
        return ["recording": .bool(zoom.isRecording), "participants": .array(zoom.participants.map { .string($0) }),
                "current_meeting": zoom.currentMeeting?.json ?? .null]
    }
}

private struct MeetingPanel: View {
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

/// The widget gallery's picture: a meeting being transcribed, from `MeetingSample`.
private struct MeetingPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                RecordingLabel(saving: false)
                Spacer()
                Button("Stop") {}.allowsHitTesting(false)
            }
            ParticipantChips(names: MeetingSample.participants)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MeetingSample.lines, id: \.self) { SegmentRow(speaker: $0.speaker, text: $0.text) }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct RecordingLabel: View {
    let saving: Bool

    var body: some View {
        Circle().fill(.red).frame(width: 8, height: 8)
        Text(saving ? "Recording" : "Transcribing").font(.callout.bold())
    }
}

private struct ParticipantChips: View {
    let names: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(names, id: \.self) { name in
                    Text(name).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.tint.opacity(0.15), in: .capsule)
                }
            }
        }
    }
}

private struct LiveTranscript: View {
    @Query private var segments: [TranscriptSegment]

    init(meetingID: UUID) {
        _segments = Query(filter: #Predicate<TranscriptSegment> { $0.meetingID == meetingID }, sort: \.createdAt)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(segments) { SegmentRow(speaker: $0.speaker, text: $0.text) }
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .onChange(of: segments.count) { proxy.scrollTo("end") }
        }
    }
}

private struct SegmentRow: View {
    let speaker: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(speaker).font(.caption.bold()).foregroundStyle(speaker == MeetingRecorder.othersSpeaker ? Color.secondary : .accentColor)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }
}

private struct MeetingSheet: View {
    let meeting: MeetingRecord
    let zoom: ZoomExtension?
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @Query private var segments: [TranscriptSegment]
    @State private var error: String?

    /// The saved file, if it is still on disk.
    private var recording: URL? {
        meeting.recordingPath.map { URL(filePath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    init(meeting: MeetingRecord, zoom: ZoomExtension?, host: any ExtensionContext) {
        self.meeting = meeting
        self.zoom = zoom
        self.host = host
        let id = meeting.id
        _segments = Query(filter: #Predicate<TranscriptSegment> { $0.meetingID == id }, sort: \.createdAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(meeting.title).font(.title3.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(meeting.participants.joined(separator: ", "))")
                .font(.caption).foregroundStyle(.secondary)
            if let recording {
                HStack {
                    Image(systemName: recording.pathExtension == "mov" ? "film" : "waveform")
                    Text(recording.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Play") { NSWorkspace.shared.open(recording) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([recording]) }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !meeting.summary.isEmpty { Text(meeting.summary).textSelection(.enabled) }
                    if !meeting.decisions.isEmpty {
                        Text("Decisions").font(.headline)
                        ForEach(meeting.decisions, id: \.self) { Text("• \($0)") }
                    }
                    if !meeting.actionItems.isEmpty {
                        Text("Action items").font(.headline)
                        ForEach(meeting.actionItems, id: \.self) { item in Text("• **\(item.owner)**: \(item.task)") }
                    }
                    Divider()
                    ForEach(segments) { SegmentRow(speaker: $0.speaker, text: $0.text) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Summarise Again") {
                    Task {
                        do { try await zoom?.summarize(meeting) } catch { self.error = error.localizedDescription }
                    }
                }
                .disabled(zoom?.isSummarizing == true)
                Button("Ask Claude", systemImage: "sparkles") {
                    host.askClaude("Read the transcript of meeting \(meeting.id.uuidString) (\(meeting.title)). Which action items should become Jira tickets?")
                    dismiss()
                }
                Spacer()
                Button(recording == nil ? "Delete" : "Delete and Trash Recording", role: .destructive) {
                    if let recording { try? FileManager.default.trashItem(at: recording, resultingItemURL: nil) }
                    for segment in segments { host.context.delete(segment) }
                    host.context.delete(meeting)
                    try? host.context.save()
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 600)
    }
}
