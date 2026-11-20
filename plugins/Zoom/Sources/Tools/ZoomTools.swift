import DashKit
import Foundation
import SwiftData

/// Dashii tools: meetings, transcripts, speakers, participants, summaries.
extension ZoomExtension {
    private struct MeetingInput: Decodable { let meeting_id: String? }

    private func resolve(_ text: String?) throws -> MeetingRecord {
        if let text, text != "current", let id = UUID(uuidString: text), let meeting = meeting(id) { return meeting }
        if let meeting = currentMeeting { return meeting }
        var descriptor = FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let latest = try host?.context.fetch(descriptor).first else { throw ToolError("No meetings recorded yet.") }
        return latest
    }

    var tools: [DashiiTool] {
        [
            DashiiTool(name: "zoom_upcoming_meetings",
                       description: "The user's Zoom meetings in the next 24 hours, from the Mac's calendars: title, start, end, calendar and join link. Empty when the calendar isn't turned on (Settings › Meetings).") { [weak self] _ in
                guard let self else { return [] }
                return ["calendar": .bool(useCalendar), "meetings": .array(upcoming.map(\.json))]
            },
            DashiiTool(name: "meetings_list", description: "List recorded meetings, newest first, with their summaries and action items.") { [weak self] _ in
                guard let self, let host else { return [] }
                var descriptor = FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
                descriptor.fetchLimit = 30
                return .array(((try? host.context.fetch(descriptor)) ?? []).map(\.json))
            },
            DashiiTool(
                name: "meeting_transcript",
                description: "Read a meeting's transcript. Once the meeting has ended, its recording is transcribed again with each voice apart: lines name the participant (a name marked (guessed) is Dashii's guess) or \"Speaker N\" for a voice not named yet. During the meeting, lines are the user (microphone), \"Others\" (everyone else), or names from Zoom's captions.",
                properties: ["meeting_id": JSONSchema.string("Meeting id, or \"current\". Defaults to the current or latest meeting.")]
            ) { [weak self] input in
                guard let self else { return nil }
                let meeting = try resolve(try input.toolInput(MeetingInput.self).meeting_id)
                return meeting.json.merging(["transcript": .string(Self.transcriptText(namedSegments(meeting.id), since: meeting.startedAt, guessed: guessedLabels(meeting.id)))])
            },
            DashiiTool(
                name: "meeting_speakers",
                description: "Who spoke in a meeting, in the order they first spoke, with when, how many lines and words, and who is speaking now. After the meeting, from the final transcript (each voice apart); during it, from Zoom's captions (without them only the user is named).",
                properties: ["meeting_id": JSONSchema.string("Meeting id, or \"current\". Defaults to the current or latest meeting.")]
            ) { [weak self] input in
                guard let self else { return nil }
                let meeting = try resolve(try input.toolInput(MeetingInput.self).meeting_id)
                let speakers = speakers(meeting.id)
                let lines = namedSegments(meeting.id)
                let latest = lines.last { $0.source == "captions" || $0.speaker == myName }
                return ["meeting_id": .string(meeting.id.uuidString), "participants": .array(meeting.participants.map { .string($0) }),
                        "named": .bool(lines.contains { $0.source == "captions" || $0.source == "final" }),
                        "speaking_now": latest.flatMap { Date.now.timeIntervalSince($0.createdAt) < 15 ? .string($0.speaker) : nil } ?? .null,
                        "speakers": .array(speakers.map { speaker in
                            ["name": .string(speaker.name), "first": .string(speaker.first.formatted(.iso8601)), "last": .string(speaker.last.formatted(.iso8601)),
                             "lines": .number(Double(speaker.lines)), "words": .number(Double(speaker.words))]
                        }),
                        "not_heard_yet": .array(meeting.participants.filter { name in !speakers.contains { $0.name == name } }.map { .string($0) })]
            },
            DashiiTool(name: "meeting_participants", description: "Who is in the Zoom meeting right now, read from Zoom's Participants panel.") { [weak self] _ in
                guard let self else { return nil }
                return ["in_meeting": .bool(inMeeting), "recording": .bool(isRecording),
                        "participants": .array(participants.map { .string($0) }),
                        "note": participants.isEmpty && inMeeting ? "Open Zoom's Participants panel so Dash can read it." : ""]
            },
            DashiiTool(
                name: "meeting_summarize",
                description: "Regenerate a meeting's title, summary, decisions and action items from its transcript.",
                properties: ["meeting_id": JSONSchema.string("Meeting id. Defaults to the latest meeting.")]
            ) { [weak self] input in
                guard let self else { return nil }
                let meeting = try resolve(try input.toolInput(MeetingInput.self).meeting_id)
                try await summarize(meeting)
                return meeting.json
            },
        ]
    }
}
