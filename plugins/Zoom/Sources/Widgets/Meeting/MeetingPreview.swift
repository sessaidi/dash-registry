import SwiftUI

/// The widget gallery's picture: a meeting being transcribed, from `MeetingSample`.
struct MeetingPreview: View {
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
