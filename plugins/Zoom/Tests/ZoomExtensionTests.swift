import DashKit
import DashKitUI
import Foundation
import SwiftData
import SwiftUI
import Testing

@Suite("Zoom extension")
@MainActor
struct ZoomExtensionTests {
    @Test func contract() {
        let (zoom, _) = makeZoom()
        #expect(zoom.id == "zoom")
        #expect(zoom.layer == .feature)
        #expect(zoom.requires.isEmpty)
        #expect(zoom.widgets.map(\.kind) == ["zoom.meeting", "zoom.upcoming"])
        #expect(zoom.tools.map(\.name) == ["zoom_upcoming_meetings", "meetings_list", "meeting_transcript", "meeting_speakers", "meeting_participants", "meeting_summarize"])
        #expect(zoom.models.count == 2)
        #expect(ZoomPlugin.makeExtensions().map(\.id) == ["zoom"])
    }

    @Test func widgetType() {
        let type = WidgetType(MeetingWidget.self)
        #expect(type.sizeLimits == GridLimits(minW: 3, minH: 4, maxW: 8, maxH: 20))
        #expect(type.defaultConfig["recentCount"]?.int == 5)
        #expect(type.preview != nil)
    }

    @Test func preferencesUseTheBuiltInKeys() {
        let defaults = UserDefaults(suiteName: "zoom-tests-\(UUID().uuidString)")!
        defaults.set("Ada", forKey: "zoom.myName")
        defaults.set("fr_FR", forKey: "zoom.locale")
        defaults.set(true, forKey: "zoom.autoStart")
        defaults.set(false, forKey: "zoom.summarize")
        let zoom = ZoomExtension(defaults: defaults)
        #expect(zoom.myName == "Ada" && zoom.localeIdentifier == "fr_FR" && zoom.autoStart && !zoom.summarizeOnStop)
        zoom.myName = "Grace"
        zoom.summarizeOnStop = true
        #expect(defaults.string(forKey: "zoom.myName") == "Grace")
        #expect(defaults.object(forKey: "zoom.summarize") as? Bool == true)

        let fresh = ZoomExtension(defaults: UserDefaults(suiteName: "zoom-tests-\(UUID().uuidString)")!)
        #expect(!fresh.autoStart && fresh.summarizeOnStop)
        #expect(fresh.saveAudio && !fresh.recordVideo)
        #expect(fresh.recordingsFolder == ZoomExtension.defaultRecordingsFolder)
        #expect(fresh.recordingOptions?.video == false)
        fresh.recordVideo = true
        #expect(fresh.recordingOptions?.video == true)
        fresh.saveAudio = false
        #expect(fresh.recordingOptions == nil)
    }

    @Test func meetingsListNewestFirst() async throws {
        let (zoom, host) = makeZoom()
        #expect(try await zoom.tool("meetings_list").run([:]) == [])
        insertMeeting(host, title: "Old", startedAt: Date(timeIntervalSince1970: 1_000))
        insertMeeting(host, title: "New", startedAt: Date(timeIntervalSince1970: 2_000))
        let list = try await zoom.tool("meetings_list").run([:])
        #expect(list.array?.compactMap { $0["title"]?.string } == ["New", "Old"])
    }

    @Test func transcriptResolvesIdOrLatest() async throws {
        let (zoom, host) = makeZoom()
        await #expect(throws: ToolError("No meetings recorded yet.")) { try await zoom.tool("meeting_transcript").run([:]) }
        let start = Date(timeIntervalSince1970: 1_000)
        let old = insertMeeting(host, title: "Old", startedAt: start, lines: [(5, "Sadik", "First"), (70, "Others", "Second")])
        insertMeeting(host, title: "New", startedAt: start.addingTimeInterval(3_600), lines: [(1, "Others", "Later")])

        let byID = try await zoom.tool("meeting_transcript").run(["meeting_id": .string(old.id.uuidString)])
        #expect(byID["title"]?.string == "Old")
        #expect(byID["transcript"]?.string == "[00:05] Sadik: First\n[01:10] Others: Second")

        let latest = try await zoom.tool("meeting_transcript").run(["meeting_id": "current"])
        #expect(latest["title"]?.string == "New")
        #expect(latest["transcript"]?.string == "[00:01] Others: Later")

        let unknown = try await zoom.tool("meeting_transcript").run(["meeting_id": .string(UUID().uuidString)])
        #expect(unknown["title"]?.string == "New")
        await #expect(throws: ToolError.self) { try await zoom.tool("meeting_transcript").run(["meeting_id": 42]) }
    }

    @Test func participantsTool() async throws {
        let (zoom, _) = makeZoom()
        var result = try await zoom.tool("meeting_participants").run([:])
        #expect(result == ["in_meeting": false, "recording": false, "participants": [], "note": ""])

        zoom.observe(inMeeting: true, participants: [])
        result = try await zoom.tool("meeting_participants").run([:])
        #expect(result["note"]?.string == "Open Zoom's Participants panel so Dash can read it.")

        zoom.observe(inMeeting: true, participants: ["Ada", "Grace"])
        result = try await zoom.tool("meeting_participants").run([:])
        #expect(result == ["in_meeting": true, "recording": false, "participants": ["Ada", "Grace"], "note": ""])
    }

    @Test func recordingLifecycle() async throws {
        let (zoom, host) = makeZoom()
        zoom.observe(inMeeting: true, participants: ["Ada"])
        let meetingID = try #require(zoom.beginMeeting())
        #expect(zoom.beginMeeting() == nil)
        #expect(zoom.isRecording && zoom.currentMeetingID == meetingID)
        #expect(zoom.currentMeeting?.participants == ["Ada"])

        // Participants who join later are added to the meeting, in order.
        zoom.observe(inMeeting: true, participants: ["Grace", "Ada"])
        #expect(zoom.currentMeeting?.participants == ["Ada", "Grace"])

        zoom.add(.init(speaker: "Sadik", text: "Morning."), to: meetingID)
        zoom.add(.init(speaker: "Others", text: "Hi."), to: meetingID)
        #expect(zoom.segments(meetingID).map(\.speaker) == ["Sadik", "Others"])

        let snapshot = await MeetingWidget.snapshot(config: MeetingWidget.defaultConfig, context: WidgetContext(widgetID: UUID(), host: host))
        #expect(snapshot["recording"] == true)
        #expect(snapshot["current_meeting"]?["id"]?.string == meetingID.uuidString)

        let current = try await zoom.tool("meeting_transcript").run(["meeting_id": "current"])
        #expect(current["transcript"]?.string?.hasSuffix("Others: Hi.") == true)

        await zoom.stopRecording()
        #expect(!zoom.isRecording && zoom.currentMeetingID == nil)
        let meeting = try #require(zoom.meeting(meetingID))
        #expect(meeting.endedAt != nil)
        #expect(host.activity.events.map(\.kind) == ["meeting.started", "meeting.ended"])
        #expect(host.fakeDashii.prompts.isEmpty)
    }

    @Test func emptyMeetingsAreDropped() async throws {
        let (zoom, host) = makeZoom()
        let meetingID = try #require(zoom.beginMeeting())
        await zoom.stopRecording()
        #expect(zoom.meeting(meetingID) == nil)
        #expect(try host.context.fetchCount(FetchDescriptor<MeetingRecord>()) == 0)
    }

    @Test func aRecordingYouStartedOnlyStopsWhenYouSaySo() async throws {
        let (zoom, host) = makeZoom()
        defer { _ = host }
        zoom.observe(inMeeting: true, participants: ["Ada"])
        _ = try #require(zoom.beginMeeting())
        // Screen sharing, the mini window, full screen: no meeting window for a long while.
        for _ in 0..<(ZoomExtension.autoStopChecks * 2) { zoom.observe(inMeeting: false, participants: []) }
        for _ in 0..<20 { await Task.yield() }
        #expect(zoom.isRecording)
        await zoom.stopRecording(reason: "You stopped it.")
        #expect(!zoom.isRecording && zoom.lastStopReason == "You stopped it.")
    }

    @Test func anAutomaticRecordingStopsAfterTwoMinutesWithoutTheMeeting() async throws {
        let (zoom, host) = makeZoom()
        zoom.observe(inMeeting: true, participants: ["Ada"])
        let meetingID = try #require(zoom.beginMeeting(automatically: true))
        zoom.add(.init(speaker: "Others", text: "Bye."), to: meetingID)
        for _ in 0..<(ZoomExtension.autoStopChecks - 1) { zoom.observe(inMeeting: false, participants: []) }
        // Back in the meeting resets the count: a short gap (a screen share) doesn't stop it.
        zoom.observe(inMeeting: true, participants: ["Ada"])
        for _ in 0..<(ZoomExtension.autoStopChecks - 1) { zoom.observe(inMeeting: false, participants: []) }
        for _ in 0..<20 { await Task.yield() }
        #expect(zoom.isRecording)
        zoom.observe(inMeeting: false, participants: [])
        for _ in 0..<20 where zoom.isRecording { await Task.yield() }
        #expect(!zoom.isRecording && zoom.lastStopReason == "No sign of the Zoom meeting for 2 minutes.")
        #expect(zoom.meeting(meetingID)?.endedAt != nil)
        #expect(host.activity.events.last?.kind == "meeting.ended")
    }

    @Test func summarizeOnStop() async throws {
        let (zoom, host) = makeZoom(summarizeOnStop: true)
        host.fakeDashii.response = """
            {"title":"Release sync","summary":"Migration ships Thursday.","decisions":["Ship Thursday"],
             "action_items":[{"owner":"Ada","task":"Post the numbers"}]}
            """
        zoom.observe(inMeeting: true, participants: ["Ada"])
        let meetingID = try #require(zoom.beginMeeting())
        zoom.add(.init(speaker: "Others", text: "The backfill finished."), to: meetingID)
        await zoom.stopRecording()

        let meeting = try #require(zoom.meeting(meetingID))
        #expect(meeting.title == "Release sync")
        #expect(meeting.summary == "Migration ships Thursday.")
        #expect(meeting.decisions == ["Ship Thursday"])
        #expect(meeting.actionItems == [.init(owner: "Ada", task: "Post the numbers")])
        #expect(host.activity.events.last?.kind == "meeting.summarized")
        let prompt = try #require(host.fakeDashii.prompts.first)
        #expect(prompt.contains("Participants seen in Zoom: Ada"))
        #expect(prompt.contains("Lines from \"Sadik\" are the user's microphone"))
        #expect(prompt.contains("Others: The backfill finished."))
    }

    @Test func theReportUsesNoteSyntaxAndNamesOthersLines() async throws {
        let (zoom, host) = makeZoom(summarizeOnStop: true)
        host.fakeDashii.response = """
            {"title":"Daily standup","summary":"Updates from the player team.",
             "people":[{"name":"Ada","done":"PR in review for favorites","next":"Repro the ads skip","blockers":""},
                       {"name":"Grace","done":"Removed unused code","next":"","blockers":"Waiting on the layout merge"}],
             "topics":[{"title":"Zapper merge","points":["On hold until the layout work lands"]}],
             "decisions":["Merge the layout work first"],"risks":["The zapper rebase may take days"],
             "action_items":[{"owner":"Ada","task":"Reproduce the iPad ads skip"}],
             "speakers":[{"line":1,"name":"Grace"},{"line":0,"name":"Nobody"},{"line":9,"name":"Out of range"}]}
            """
        zoom.observe(inMeeting: true, participants: ["Ada", "Grace"])
        let meetingID = try #require(zoom.beginMeeting())
        zoom.add(.init(speaker: "Sadik", text: "Morning."), to: meetingID)
        zoom.add(.init(speaker: "Others", text: "I removed the unused code."), to: meetingID)
        await zoom.stopRecording()

        let meeting = try #require(zoom.meeting(meetingID))
        #expect(meeting.report.hasPrefix("> [!summary]"))
        #expect(meeting.report.contains("| **Ada** | PR in review for favorites | Repro the ads skip | — |"))
        #expect(meeting.report.contains("### Zapper merge\n- On hold until the layout work lands"))
        #expect(meeting.report.contains("> [!warning] Risk\n> The zapper rebase may take days"))
        #expect(meeting.report.contains("- [ ] **Ada**: Reproduce the iPad ads skip"))
        // Only an Others line is renamed, and it's marked as a guess.
        let lines = zoom.segments(meetingID)
        #expect(lines.map(\.speaker) == ["Sadik", "Grace"] && lines[1].source == "inferred")
        #expect(ZoomExtension.transcriptText(lines, since: meeting.startedAt).contains("Grace (guessed): I removed"))
        #expect(try #require(host.fakeDashii.prompts.first).contains("[1] [00:00] Others: I removed the unused code."))
    }

    @Test func summarizeTool() async throws {
        let (zoom, host) = makeZoom()
        let meeting = insertMeeting(host, title: "Zoom meeting", startedAt: .now, lines: [(1, "Sadik", "Let's ship it.")])
        host.fakeDashii.response = #"{"title":"Ship it","summary":"Agreed to ship.","decisions":[],"action_items":[]}"#
        let result = try await zoom.tool("meeting_summarize").run(["meeting_id": .string(meeting.id.uuidString)])
        #expect(result["title"]?.string == "Ship it")
        #expect(result["summary"]?.string == "Agreed to ship.")
        #expect(result["action_items"] == [])

        host.fakeDashii.response = "not json"
        await #expect(throws: (any Error).self) { try await zoom.tool("meeting_summarize").run([:]) }
        #expect(!zoom.isSummarizing)
    }
}
