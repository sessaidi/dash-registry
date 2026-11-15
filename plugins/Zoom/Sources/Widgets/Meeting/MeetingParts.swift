import SwiftData
import SwiftUI

/// One transcript line as the widget shows it, live or sample.
typealias TranscriptLine = MeetingSample.Line

/// The red dot and Recording / Transcribing.
struct RecordingLabel: View {
    let saving: Bool

    var body: some View {
        Circle().fill(.red).frame(width: 8, height: 8)
        Text(saving ? "Recording" : "Transcribing").font(.callout.bold())
    }
}

/// Who is in the meeting, as chips.
struct ParticipantChips: View {
    let names: [String]

    var body: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(names, id: \.self) { name in
                    Text(name).font(.caption).padding(.horizontal, 8).padding(.vertical, 3).background(.tint.opacity(0.15), in: .capsule)
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// The current meeting's transcript lines, followed live, handed to `content`.
struct LiveSegments<Content: View>: View {
    @Query private var segments: [TranscriptSegment]
    let content: ([TranscriptLine]) -> Content

    init(meetingID: UUID, @ViewBuilder content: @escaping ([TranscriptLine]) -> Content) {
        _segments = Query(filter: #Predicate<TranscriptSegment> { $0.meetingID == meetingID }, sort: \.createdAt)
        self.content = content
    }

    var body: some View {
        content(segments.map { TranscriptLine(speaker: $0.speaker, text: $0.text) })
    }
}

/// A transcript, following new lines.
struct TranscriptView: View {
    let lines: [TranscriptLine]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in SegmentRow(speaker: line.speaker, text: line.text) }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: lines.count) { proxy.scrollTo("end") }
            .onAppear { proxy.scrollTo("end") }
        }
    }
}

/// One transcript line: speaker and text.
struct SegmentRow: View {
    let speaker: String
    let text: String
    /// Two lines at most, for the narrow glance.
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(speaker).font(.caption.bold()).foregroundStyle(speaker == MeetingRecorder.othersSpeaker ? Color.secondary : .accentColor)
            Text(text).font(compact ? .caption : .callout).lineLimit(compact ? 2 : nil).textSelection(.enabled)
        }
    }
}
