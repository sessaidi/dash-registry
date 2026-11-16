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
    @State private var error: String?
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
                        if segments.contains(where: { $0.source == "inferred" }) {
                            Label("Names marked ≈ were guessed by Dashii from what was said. Open Zoom's transcript panel during the meeting for exact names.",
                                  systemImage: "person.fill.questionmark").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(segments) { SegmentRow(speaker: $0.source == "inferred" ? "≈ " + $0.speaker : $0.speaker, text: $0.text) }
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
    }
}
