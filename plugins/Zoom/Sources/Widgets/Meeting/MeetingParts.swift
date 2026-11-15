import SwiftData
import SwiftUI

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
    }
}

/// The current meeting's transcript, following new lines.
struct LiveTranscript: View {
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

/// One transcript line: speaker and text.
struct SegmentRow: View {
    let speaker: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(speaker).font(.caption.bold()).foregroundStyle(speaker == MeetingRecorder.othersSpeaker ? Color.secondary : .accentColor)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }
}
