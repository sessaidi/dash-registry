import DashKit
import DashKitUI
import SwiftUI

/// A past meeting as the widget shows it; decoupled from SwiftData so previews can use samples.
struct MeetingDigest: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let startedAt: Date
    let endedAt: Date?
    let participants: [String]
    let summary: String
    let decisions: [String]
    let actionItems: [MeetingRecord.ActionItem]

    init(id: UUID, title: String, startedAt: Date, endedAt: Date?, participants: [String], summary: String, decisions: [String],
         actionItems: [MeetingRecord.ActionItem]) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.participants = participants
        self.summary = summary
        self.decisions = decisions
        self.actionItems = actionItems
    }

    init(_ record: MeetingRecord) {
        self.init(id: record.id, title: record.title, startedAt: record.startedAt, endedAt: record.endedAt, participants: record.participants,
                  summary: record.summary, decisions: record.decisions, actionItems: record.actionItems)
    }

    /// "Mon 14:00 · 30 min".
    var when: String {
        let start = startedAt.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        guard let endedAt else { return start }
        return "\(start) · \(max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))) min"
    }
}

/// What Zoom is doing now, as the widget shows it.
struct MeetingLive: Equatable {
    var zoomRunning = false
    var inMeeting = false
    var recording = false
    /// Recording keeps a file (Record); otherwise it only transcribes (Transcribe).
    var saveAudio = false
    var recordVideo = false
    var summarizing = false
    var error: String?
    var participants: [String] = []
    /// The meeting being transcribed, when there is one.
    var meetingID: UUID?
    var title: String?
    var startedAt: Date?

    var isLive: Bool { meetingID != nil }
    var status: String { inMeeting ? "In a Zoom meeting" : zoomRunning ? "Zoom is open" : "Zoom is not running" }
}

/// What the widget's buttons do; no-ops in the gallery.
struct MeetingCommands {
    var record: () -> Void = {}
    var stop: () -> Void = {}
    var setVideo: (Bool) -> Void = { _ in }
    /// Opens a past meeting's sheet (summary, transcript, recording).
    var open: (UUID) -> Void = { _ in }
}

/// The Meeting widget at any size: one layout per size family, live or from samples.
///
/// - narrow: the live meeting and its timer with Stop, else the last meeting and Transcribe.
/// - medium: controls, participants, and the live transcript or past meetings.
/// - wide: the transcript beside the people and timer, or past meetings beside the chosen one's summary.
/// - large: the transcript with people, last time's action items and recent meetings; or totals,
///   past meetings and the chosen one's summary, decisions and action items.
struct MeetingLayout: View {
    let live: MeetingLive
    let lines: [TranscriptLine]
    let past: [MeetingDigest]
    var commands = MeetingCommands()
    /// The query bar's text and how many meetings it filtered, for "3 of 12".
    var query = ""
    var total = 0
    @Environment(\.widgetLayout) private var layout
    @State private var focusedID: UUID?

    private var focused: MeetingDigest? { past.first { $0.id == focusedID } ?? past.first }

    var body: some View {
        switch layout.family {
        case .narrow:
            MeetingGlance(live: live, lines: lines, last: past.first, commands: commands, room: layout.size.height)
        case .wide:
            VStack(alignment: .leading, spacing: 8) {
                MeetingControls(live: live, commands: commands)
                if live.isLive {
                    HStack(alignment: .top, spacing: 12) {
                        TranscriptView(lines: lines).frame(maxWidth: .infinity)
                        Divider()
                        PeoplePanel(live: live).frame(width: 200, alignment: .topLeading)
                    }
                } else {
                    pastSplit
                }
            }
        case .large:
            VStack(alignment: .leading, spacing: 10) {
                MeetingControls(live: live, commands: commands)
                if live.isLive {
                    HStack(alignment: .top, spacing: 12) {
                        TranscriptView(lines: lines).frame(maxWidth: .infinity)
                        Divider()
                        VStack(alignment: .leading, spacing: 14) {
                            PeoplePanel(live: live)
                            if let last = past.first, !last.actionItems.isEmpty {
                                ActionItemsList(title: "From \(last.title)", items: last.actionItems)
                            }
                            RecentMeetings(past: Array(past.prefix(4)), open: commands.open)
                            Spacer(minLength: 0)
                        }
                        .frame(width: 240)
                    }
                } else {
                    MeetingTotals(past: past)
                    Divider()
                    pastSplit
                }
            }
        default:
            MeetingCard(live: live, lines: lines, past: past, commands: commands, query: query, total: total)
        }
    }

    /// Past meetings on the left, the chosen one on the right.
    @ViewBuilder
    private var pastSplit: some View {
        if past.isEmpty {
            MeetingsEmpty(live: live)
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    QueryCount(shown: past.count, total: total, query: query)
                    List(past) { meeting in
                        ItemRow(meeting.title, subtitle: meeting.when) {
                            Image(systemName: "video").foregroundStyle(.secondary)
                        } trailing: {
                            if !meeting.actionItems.isEmpty { Badge("\(meeting.actionItems.count)", tone: .info, systemImage: "checklist") }
                        }
                        .onTapGesture { focusedID = meeting.id }
                        .listRowBackground(focused?.id == meeting.id ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
                .frame(maxWidth: .infinity)
                Divider()
                if let focused {
                    MeetingDigestView(meeting: focused, open: commands.open)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
    }
}

/// Narrow: what's happening and the one button that matters.
struct MeetingGlance: View {
    let live: MeetingLive
    let lines: [TranscriptLine]
    let last: MeetingDigest?
    let commands: MeetingCommands
    let room: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if live.isLive {
                HStack(spacing: 6) {
                    RecordingLabel(saving: live.saveAudio)
                    Spacer(minLength: 4)
                    if let startedAt = live.startedAt {
                        Text(startedAt, style: .timer).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(live.title ?? "Zoom meeting").font(.headline).lineLimit(1)
                if !live.participants.isEmpty {
                    Label("\(live.participants.count) in the meeting", systemImage: "person.2").font(.caption).foregroundStyle(.secondary)
                        .help(live.participants.joined(separator: ", "))
                }
                // The latest lines that fit.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.suffix(max(1, Int((room - 100) / 40))).enumerated()), id: \.offset) { _, line in
                        SegmentRow(speaker: line.speaker, text: line.text, compact: true)
                    }
                }
                Spacer(minLength: 0)
                Button("Stop", systemImage: "stop.fill", action: commands.stop).controlSize(.small)
            } else {
                Text(live.status).font(.callout).foregroundStyle(.secondary)
                if let last {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(last.title).font(.headline).lineLimit(1)
                        Text(last.when).font(.caption).foregroundStyle(.secondary)
                        if !last.actionItems.isEmpty {
                            Label("\(last.actionItems.count) action item\(last.actionItems.count == 1 ? "" : "s")", systemImage: "checklist")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(.rect)
                    .onTapGesture { commands.open(last.id) }
                } else {
                    Text("No meetings yet").font(.headline)
                }
                Spacer(minLength: 0)
                RecordButton(live: live, commands: commands, prominent: true)
            }
            if let error = live.error { Text(error).font(.caption).foregroundStyle(.red).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Medium: controls, participants, then the live transcript or the past meetings.
struct MeetingCard: View {
    let live: MeetingLive
    let lines: [TranscriptLine]
    let past: [MeetingDigest]
    let commands: MeetingCommands
    let query: String
    let total: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MeetingControls(live: live, commands: commands)
            if live.inMeeting, !live.participants.isEmpty { ParticipantChips(names: live.participants) }
            if live.isLive {
                TranscriptView(lines: lines)
            } else if past.isEmpty {
                MeetingsEmpty(live: live)
            } else {
                QueryCount(shown: past.count, total: total, query: query)
                List(past) { meeting in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(meeting.title).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(meeting.startedAt.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                        }
                        Text(meeting.summary.isEmpty ? meeting.when : meeting.summary)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .contentShape(.rect)
                    .onTapGesture { commands.open(meeting.id) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

/// Status (or Recording with its timer), the video toggle and Record / Transcribe / Stop.
struct MeetingControls: View {
    let live: MeetingLive
    let commands: MeetingCommands

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if live.recording {
                    RecordingLabel(saving: live.saveAudio)
                    if let startedAt = live.startedAt {
                        Text(startedAt, style: .timer).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                } else {
                    Text(live.status).font(.callout).foregroundStyle(.secondary)
                }
                if live.summarizing {
                    ProgressView().controlSize(.small)
                    Text("Summarizing…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if live.saveAudio {
                    // Applies to the next recording: the capture's video is set when it starts.
                    Toggle(isOn: Binding(get: { live.recordVideo }, set: commands.setVideo)) {
                        Image(systemName: live.recordVideo ? "video.fill" : "video.slash")
                    }
                    .toggleStyle(.button)
                    .help(live.recordVideo ? "Video on: Zoom's windows are recorded too" : "Video off: audio only")
                    .disabled(live.recording)
                }
                RecordButton(live: live, commands: commands, prominent: false)
            }
            if let error = live.error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

/// Stop while recording, else Record or Transcribe (needs Zoom open).
struct RecordButton: View {
    let live: MeetingLive
    let commands: MeetingCommands
    let prominent: Bool

    var body: some View {
        if live.recording {
            Button("Stop", action: commands.stop)
        } else if prominent {
            Button(live.saveAudio ? "Record" : "Transcribe", systemImage: live.saveAudio ? "record.circle" : "waveform", action: commands.record)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!live.zoomRunning)
                .help(live.zoomRunning ? "Start following this meeting" : "Open Zoom first")
        } else {
            Button(live.saveAudio ? "Record" : "Transcribe", action: commands.record).disabled(!live.zoomRunning)
        }
    }
}

/// The meeting and who's in it, beside the transcript.
struct PeoplePanel: View {
    let live: MeetingLive

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The timer is in the controls row above.
            Text(live.title ?? "Zoom meeting").font(.headline).lineLimit(2)
            if let startedAt = live.startedAt {
                Text("Started \(startedAt.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Text("Participants · \(live.participants.count)").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 4)
            ForEach(live.participants, id: \.self) { name in
                HStack(spacing: 6) {
                    StatusDot(.success)
                    Text(name).font(.callout).lineLimit(1)
                }
            }
            if live.participants.isEmpty { Text("No one seen yet").font(.callout).foregroundStyle(.tertiary) }
        }
    }
}

/// A meeting's summary, decisions and action items, with Open for the transcript and recording.
struct MeetingDigestView: View {
    let meeting: MeetingDigest
    let open: (UUID) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.headline)
                    Text(([meeting.when] + (meeting.participants.isEmpty ? [] : ["\(meeting.participants.count) people"])).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if meeting.summary.isEmpty {
                    Text("Not summarized yet.").font(.callout).foregroundStyle(.tertiary)
                } else {
                    Text(meeting.summary).font(.callout).textSelection(.enabled)
                }
                if !meeting.decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Decisions").font(.caption.bold()).foregroundStyle(.secondary)
                        ForEach(meeting.decisions, id: \.self) { decision in
                            Label(decision, systemImage: "checkmark.seal").font(.callout)
                        }
                    }
                }
                if !meeting.actionItems.isEmpty { ActionItemsList(title: "Action items", items: meeting.actionItems) }
                Button("Open Meeting") { open(meeting.id) }.controlSize(.small).help("Transcript, recording and summary")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Owner: task lines.
struct ActionItemsList: View {
    let title: String
    let items: [MeetingRecord.ActionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary).lineLimit(1)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Badge(item.owner, tone: .accent)
                    Text(item.task).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The last few meetings, each opening its sheet.
struct RecentMeetings: View {
    let past: [MeetingDigest]
    let open: (UUID) -> Void

    var body: some View {
        if !past.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(past) { meeting in
                    Button { open(meeting.id) } label: {
                        ItemRow(meeting.title, subtitle: meeting.when)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Large: the week in numbers.
struct MeetingTotals: View {
    let past: [MeetingDigest]

    var body: some View {
        let week = past.filter { $0.startedAt > .now.addingTimeInterval(-7 * 24 * 3600) }
        let minutes = week.reduce(0) { $0 + Int(($1.endedAt ?? $1.startedAt).timeIntervalSince($1.startedAt) / 60) }
        HStack(spacing: 16) {
            stat("\(week.count)", "Meetings this week")
            stat(minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m", "In meetings")
            stat("\(week.reduce(0) { $0 + $1.actionItems.count })", "Action items")
            stat("\(week.reduce(0) { $0 + $1.decisions.count })", "Decisions")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// No meetings yet: how to get one.
struct MeetingsEmpty: View {
    let live: MeetingLive

    var body: some View {
        ContentUnavailableView("No meetings yet", systemImage: "waveform",
                               description: Text(live.saveAudio ? "Join a Zoom meeting and press Record." : "Join a Zoom meeting and press Transcribe."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
