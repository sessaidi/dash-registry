import AppKit
import DashKit
import SwiftData
import SwiftUI

/// A past meeting: summary, decisions, action items, transcript and recording.
struct MeetingSheet: View {
    let meeting: MeetingRecord
    let zoom: ZoomExtension?
    let host: any ExtensionContext
    @Environment(\.dismiss) private var dismiss
    @Query private var segments: [TranscriptSegment]
    @Query private var voices: [MeetingSpeaker]
    @State private var error: String?
    /// The voice being named with "Other Name…".
    @State private var naming: String?
    @State private var typedName = ""
    @State private var tab = Tab.report
    @State private var saved: String?

    enum Tab: String, CaseIterable { case report = "Report", transcript = "Transcript" }

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
        _voices = Query(filter: #Predicate<MeetingSpeaker> { $0.meetingID == id }, sort: \.seconds, order: .reverse)
    }

    private var lines: [TranscriptSegment] { ZoomExtension.readable(segments) }
    private var guessed: Set<String> { Set(voices.filter(\.isGuess).map(\.label)) }
    private var progress: ZoomExtension.ImproveProgress? { zoom?.improving.flatMap { $0.meetingID == meeting.id ? $0 : nil } }

    private func isGuess(_ segment: TranscriptSegment) -> Bool {
        segment.source == "inferred" || (segment.source == "final" && guessed.contains(segment.speakerLabel))
    }

    /// What a voice's lines show: its name, or "Speaker N".
    private func shownName(_ voice: MeetingSpeaker) -> String {
        voice.name.isEmpty ? lines.first { $0.speakerLabel == voice.label }?.speaker ?? voice.label : voice.name
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
                    Button(meeting.improvedAt == nil ? "Improve Transcript" : "Transcribe Again", systemImage: "waveform.badge.magnifyingglass") { improve() }
                        .disabled(zoom == nil || zoom?.improving != nil)
                        .help("Transcribes the recording again on this Mac, each voice apart, and names the voices you named before.")
                }
            }
            if let progress {
                HStack {
                    if let fraction = progress.fraction { ProgressView(value: fraction).frame(width: 120) } else { ProgressView().controlSize(.small) }
                    Text(progress.step + "…").font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("View", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if tab == .report {
                        if !meeting.report.isEmpty {
                            host.markdown(meeting.report)
                        } else {
                            // Meetings summarised before reports: what they have.
                            if !meeting.summary.isEmpty { Text(meeting.summary).textSelection(.enabled) }
                            if !meeting.decisions.isEmpty {
                                Text("Decisions").font(.headline)
                                ForEach(meeting.decisions, id: \.self) { Text("• \($0)") }
                            }
                            if !meeting.actionItems.isEmpty {
                                Text("Action items").font(.headline)
                                ForEach(meeting.actionItems, id: \.self) { item in Text("• **\(item.owner)**: \(item.task)") }
                            }
                            Text("Summarise Again for the full report.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        if meeting.improvedAt != nil, !voices.isEmpty { speakerChips }
                        if lines.contains(where: isGuess) {
                            Label(meeting.improvedAt == nil
                                  ? "Names marked ≈ were guessed by Dashii from what was said. Open Zoom's transcript panel during the meeting for exact names."
                                  : "Names marked ≈ were guessed by Dashii from what was said: click a voice above to confirm or change it.",
                                  systemImage: "person.fill.questionmark").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(lines) { SegmentRow(speaker: isGuess($0) ? "≈ " + $0.speaker : $0.speaker, text: $0.text) }
                    }
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
                if !meeting.report.isEmpty {
                    Button("Copy Report", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("# \(meeting.title)\n\n" + meeting.report, forType: .string)
                    }
                    Button(saved == nil ? "Save as Note" : "Saved", systemImage: "note.text.badge.plus") {
                        do {
                            _ = try host.createNote(title: meeting.title, markdown: meeting.report, folder: "Meetings")
                            saved = meeting.title
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(saved != nil)
                }
                Button("Ask Dashii", systemImage: "sparkles") {
                    host.askDashii("Read the transcript of meeting \(meeting.id.uuidString) (\(meeting.title)). Which action items should become Jira tickets?")
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
        .frame(width: 720, height: 680)
        .alert("Name this voice", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $typedName)
            Button("Name") { if let naming { zoom?.rename(naming, in: meeting.id, to: typedName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its lines are renamed, and later meetings recognise the voice.")
        }
    }

    /// Each voice, loudest first: click to name it (a participant, or another name).
    private var speakerChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(voices) { voice in
                    let name = (voice.isGuess ? "≈ " : "") + shownName(voice)
                    let minutes = max(1, Int((voice.seconds / 60).rounded()))
                    Menu {
                        ForEach(meeting.participants.filter { participant in !voices.contains { $0.name == participant && !$0.isGuess } }, id: \.self) { participant in
                            Button(participant) { zoom?.rename(voice.label, in: meeting.id, to: participant) }
                        }
                        if voice.isGuess { Button("Confirm \(voice.name)") { zoom?.rename(voice.label, in: meeting.id, to: voice.name) } }
                        Divider()
                        Button("Other Name…") {
                            typedName = voice.name
                            naming = voice.label
                        }
                    } label: {
                        Label("\(name) · \(minutes) min", systemImage: voice.label == "me" ? "mic" : voice.name.isEmpty ? "person.crop.circle.badge.questionmark" : "person.crop.circle")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .disabled(zoom == nil)
                }
            }
        }
    }

    private func improve() {
        guard let zoom else { return }
        error = nil
        Task {
            do {
                try await zoom.improveTranscript(meeting)
                if meeting.improvedAt != nil, zoom.summarizeOnStop { try await zoom.summarize(meeting) }
            } catch { self.error = error.localizedDescription }
        }
    }
}
