import DashKit
import Foundation
import ScreenCaptureKit
import Testing

@Suite("Meeting models")
@MainActor
struct MeetingModelTests {
    @Test func actionItemsRoundTrip() {
        let meeting = MeetingRecord(title: "Sync")
        #expect(meeting.actionItems.isEmpty)
        meeting.actionItems = [.init(owner: "Ada", task: "Post the numbers"), .init(owner: "Grace", task: "Open a ticket")]
        #expect(meeting.actionItems.map(\.owner) == ["Ada", "Grace"])
        meeting.actionItemsData = Data("not json".utf8)
        #expect(meeting.actionItems.isEmpty)
    }

    @Test func json() throws {
        let meeting = MeetingRecord(title: "Sync")
        meeting.participants = ["Ada", "Grace"]
        meeting.decisions = ["Ship Thursday"]
        meeting.actionItems = [.init(owner: "Ada", task: "Post the numbers")]
        let json = meeting.json
        #expect(json["id"]?.string == meeting.id.uuidString)
        #expect(json["title"]?.string == "Sync")
        #expect(json["ended"] == .null)
        #expect(json["participants"]?.array?.compactMap(\.string) == ["Ada", "Grace"])
        #expect(json["decisions"]?.array?.compactMap(\.string) == ["Ship Thursday"])
        #expect(json["action_items"]?[0]?["owner"]?.string == "Ada")
        #expect(json["action_items"]?[0]?["task"]?.string == "Post the numbers")
        meeting.endedAt = meeting.startedAt.addingTimeInterval(60)
        #expect(meeting.json["ended"]?.string != nil)
    }

    @Test func transcriptText() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let meetingID = UUID()
        let lines = [(0.0, "Sadik", "Morning."), (65.4, "Others", "Hi, can you hear me?"), (3_601, "Sadik", "Yes.")].map { seconds, speaker, text in
            let segment = TranscriptSegment(meetingID: meetingID, speaker: speaker, text: text)
            segment.createdAt = start.addingTimeInterval(seconds)
            return segment
        }
        #expect(ZoomExtension.transcriptText(lines, since: start) == """
            [00:00] Sadik: Morning.
            [01:05] Others: Hi, can you hear me?
            [60:01] Sadik: Yes.
            """)
        #expect(ZoomExtension.transcriptText([], since: start) == "")
    }

    @Test func mergedParticipantsKeepFirstSeenOrder() {
        #expect(MeetingRecord.merged([], ["Ada", "Grace"]) == ["Ada", "Grace"])
        #expect(MeetingRecord.merged(["Ada", "Grace"], ["Alan", "Ada"]) == ["Ada", "Grace", "Alan"])
        #expect(MeetingRecord.merged(["Ada"], []) == ["Ada"])
    }

    @Test func participantNames() {
        #expect(ZoomAccessibility.clean("Ada Lovelace (Host, me)") == "Ada Lovelace")
        #expect(ZoomAccessibility.clean("  Grace Hopper \n") == "Grace Hopper")
        #expect(ZoomAccessibility.clean("Alan (Guest)") == "Alan")
        #expect(ZoomAccessibility.unique(["Ada", "Grace", "Ada", "Alan", "Grace"]) == ["Ada", "Grace", "Alan"])
    }

    @Test func meetingWindows() {
        #expect(ZoomAccessibility.isMeetingWindow("Zoom Meeting"))
        #expect(ZoomAccessibility.isMeetingWindow("Zoom Webinar ID: 123"))
        #expect(ZoomAccessibility.isMeetingWindow("Meeting"))
        #expect(!ZoomAccessibility.isMeetingWindow("Zoom Workplace"))
        #expect(!ZoomAccessibility.isMeetingWindow("Participants (3)"))
    }

    @Test func sampleMeeting() {
        #expect(MeetingSample.participants.count >= 2)
        #expect(MeetingSample.lines.count >= 3)
        #expect(MeetingSample.lines.contains { $0.speaker == MeetingRecorder.othersSpeaker })
        #expect(MeetingSample.lines.contains { $0.speaker != MeetingRecorder.othersSpeaker })
    }
}

@Suite("Speaker attribution")
struct SpeakerAttributionTests {
    @Test func microphoneIsYouZoomIsOthers() {
        #expect(MeetingRecorder.speaker(for: .microphone, myName: "Sadik") == "Sadik")
        #expect(MeetingRecorder.speaker(for: .audio, myName: "Sadik") == "Others")
        #expect(MeetingRecorder.speaker(for: .screen, myName: "Sadik") == "Others")
        #expect(MeetingRecorder.othersSpeaker == "Others")
    }

    @Test func segmentsAreTrimmedAndBlanksDropped() throws {
        let segment = try #require(TranscriptionPipeline.segment(speaker: "Others", text: "  Let's start.\n"))
        #expect(segment.speaker == "Others")
        #expect(segment.text == "Let's start.")
        #expect(TranscriptionPipeline.segment(speaker: "Sadik", text: " \n\t") == nil)
    }
}
