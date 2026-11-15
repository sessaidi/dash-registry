import DashKit
import Foundation
import SwiftData

// The model names (MeetingRecord, TranscriptSegment) and their properties are the ones Dash's
// built-in Zoom extension stored, so meetings recorded before the move keep loading.

@Model
final class MeetingRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    /// Everyone seen in Zoom's participant list during the meeting.
    var participants: [String]
    var summary: String
    var decisions: [String]
    var actionItemsData: Data
    /// The saved audio (.m4a) or audio-and-video (.mov) file, when recording was on.
    var recordingPath: String?

    init(title: String) {
        id = UUID()
        self.title = title
        startedAt = .now
        participants = []
        summary = ""
        decisions = []
        actionItemsData = Data("[]".utf8)
    }

    struct ActionItem: Codable, Hashable, Sendable {
        let owner: String
        let task: String
    }

    var actionItems: [ActionItem] {
        get { (try? JSONDecoder().decode([ActionItem].self, from: actionItemsData)) ?? [] }
        set { actionItemsData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8) }
    }

    /// `seen` plus the names in `names` it doesn't have yet, in first-seen order.
    static func merged(_ seen: [String], _ names: [String]) -> [String] {
        seen + names.filter { !seen.contains($0) }
    }

    var json: JSONValue {
        ["id": .string(id.uuidString), "title": .string(title), "started": .string(startedAt.formatted(.iso8601)),
         "ended": endedAt.map { .string($0.formatted(.iso8601)) } ?? .null,
         "participants": .array(participants.map { .string($0) }), "summary": .string(summary),
         "decisions": .array(decisions.map { .string($0) }),
         "action_items": (try? JSONValue(encoding: actionItems)) ?? [],
         "recording": recordingPath.map { .string($0) } ?? .null]
    }
}

@Model
final class TranscriptSegment {
    var id: UUID
    var meetingID: UUID
    /// Your name for microphone audio; "Others" for audio coming out of Zoom.
    var speaker: String
    var text: String
    var createdAt: Date
    /// audio (on-device transcription: you or "Others"), or captions (Zoom's own captions,
    /// with each participant's name).
    var source: String = "audio"

    init(meetingID: UUID, speaker: String, text: String, source: String = "audio") {
        id = UUID()
        self.meetingID = meetingID
        self.speaker = speaker
        self.text = text
        createdAt = .now
        self.source = source
    }
}

/// The sample meeting widget previews draw: no capture, no store. A meeting being transcribed,
/// and a few past ones with summaries, so every size family looks real.
enum MeetingSample {
    struct Line: Hashable, Sendable {
        let speaker: String
        let text: String
    }

    static let title = "Weekly sync"
    static let participants = ["Ada Lovelace", "Grace Hopper", "Alan Turing", "Katherine Johnson", "Linus Torvalds"]
    /// Twelve minutes in.
    static var startedAt: Date { .now.addingTimeInterval(-12 * 60 - 4) }
    static let lines = [
        Line(speaker: "Ada Lovelace", text: "Let's start with the release. Is the migration ready for Thursday?"),
        Line(speaker: MeetingRecorder.othersSpeaker, text: "Almost. The backfill finished overnight; I still need to check the indexes."),
        Line(speaker: "Ada Lovelace", text: "Great. Can you post the numbers in the channel before standup?"),
        Line(speaker: MeetingRecorder.othersSpeaker, text: "Will do. I'll also open a ticket for the flaky integration test."),
        Line(speaker: "Ada Lovelace", text: "Next: the on-call rotation. Who takes the week of the 24th?"),
        Line(speaker: MeetingRecorder.othersSpeaker, text: "I can, if someone swaps the Friday with me."),
        Line(speaker: "Ada Lovelace", text: "Done, I'll take Friday. Last item is the dashboard latency."),
        Line(speaker: MeetingRecorder.othersSpeaker, text: "p95 is back under 300 ms since the cache change; I'll keep an eye on it."),
    ]

    /// Past meetings, newest first.
    static var past: [MeetingDigest] {
        let day: TimeInterval = 24 * 3600
        return [
            MeetingDigest(id: UUID(), title: "Release planning", startedAt: .now.addingTimeInterval(-day), endedAt: .now.addingTimeInterval(-day + 1800),
                          participants: ["Ada Lovelace", "Grace Hopper", "Alan Turing"],
                          summary: "Agreed to ship the migration Thursday behind a flag, with the backfill verified first.",
                          decisions: ["Ship Thursday behind the migration flag", "Freeze schema changes until Monday"],
                          actionItems: [.init(owner: "Grace", task: "Verify the backfill counts"), .init(owner: "Alan", task: "Write the rollback runbook"),
                                        .init(owner: "Ada", task: "Announce the freeze in #backend")]),
            MeetingDigest(id: UUID(), title: "Incident review: checkout 502s", startedAt: .now.addingTimeInterval(-3 * day),
                          endedAt: .now.addingTimeInterval(-3 * day + 2700), participants: ["Ada Lovelace", "Linus Torvalds"],
                          summary: "A connection pool limit caused the 502s; raised it and added an alert on saturation.",
                          decisions: ["Alert at 80% pool saturation"],
                          actionItems: [.init(owner: "Linus", task: "Add the saturation alert")]),
            MeetingDigest(id: UUID(), title: "1:1 with Grace", startedAt: .now.addingTimeInterval(-6 * day), endedAt: .now.addingTimeInterval(-6 * day + 1500),
                          participants: ["Ada Lovelace", "Grace Hopper"], summary: "Career goals for next quarter and the conference talk.",
                          decisions: [], actionItems: [.init(owner: "Ada", task: "Review the talk outline")]),
        ]
    }
}
