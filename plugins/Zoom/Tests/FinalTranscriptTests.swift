import DashKit
import Foundation
import MeetingSpeech
import SwiftData
import Testing

/// Canned speech: Zoom's track is the samples starting with 0, the microphone's with 1.
struct FakeSpeechEngine: SpeechEngine {
    var ready = true
    var zoom: [SpokenWord] = []
    var mic: [SpokenWord] = []
    var diarization = Diarization(turns: [], voiceprints: [:])

    var isReady: Bool { ready }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }
    func transcribe(_ samples: [Float]) async throws -> [SpokenWord] { samples.first == 1 ? mic : zoom }
    func diarize(_ samples: [Float]) async throws -> Diarization { diarization }
}

/// `text`'s words, `step` seconds each, from `start`.
func spoken(_ text: String, at start: TimeInterval, step: TimeInterval = 0.4) -> [SpokenWord] {
    text.split(separator: " ").enumerated().map { index, word in
        SpokenWord(text: String(word), start: start + Double(index) * step, end: start + Double(index + 1) * step - 0.05)
    }
}

@MainActor
struct TranscriptBuilderTests {
    @Test func piecesBecomeWords() {
        let pieces: [(text: String, start: TimeInterval, end: TimeInterval, confidence: Float)] =
            [(" The", 0, 0.2, 0.9), (" w", 0.3, 0.4, 0.8), ("he", 0.4, 0.5, 0.95), ("el", 0.5, 0.6, 0.9), (".", 0.6, 0.65, 0.7), ("▁Bonjour", 1, 1.4, 1)]
        let words = SpokenWord.words(pieces: pieces)
        #expect(words.map(\.text) == ["The", "wheel.", "Bonjour"])
        #expect(words[1].start == 0.3 && words[1].end == 0.65 && words[1].confidence == 0.7)
    }

    @Test func linesSplitOnVoicePauseAndSentence() {
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 3), SpeakerTurn(speaker: "S2", start: 3.1, end: 6)]
        let words = spoken("Is the migration ready?", at: 0) + spoken("Almost, I check the indexes.", at: 3.2) + spoken("Later then.", at: 10)
        let lines = TranscriptBuilder.lines(words) { TranscriptBuilder.speaker(at: ($0.start + $0.end) / 2, in: turns) ?? "" }
        #expect(lines.map(\.label) == ["S1", "S2", ""])
        #expect(lines.map(\.text) == ["Is the migration ready?", "Almost, I check the indexes.", "Later then."])
        // A line longer than `sentenceAfter` ends at its sentence end.
        let long = TranscriptBuilder.lines(spoken("one two three four five six seven eight nine ten. Next sentence", at: 0, step: 0.5)) { _ in "S1" }
        #expect(long.map(\.text) == ["one two three four five six seven eight nine ten.", "Next sentence"])
    }

    @Test func speakerIsTheTurnAtTheWordOrTheNearestWithinASecond() {
        let turns = [SpeakerTurn(speaker: "S1", start: 0, end: 2), SpeakerTurn(speaker: "S2", start: 5, end: 8)]
        #expect(TranscriptBuilder.speaker(at: 1, in: turns) == "S1")
        #expect(TranscriptBuilder.speaker(at: 2.5, in: turns) == "S1")
        #expect(TranscriptBuilder.speaker(at: 4.5, in: turns) == "S2")
        #expect(TranscriptBuilder.speaker(at: 3.5, in: turns) == nil)
    }

    @Test func yourMicrophoneHearingZoomIsDropped() {
        let others = spoken("the backfill finished overnight", at: 0)
        let mine = spoken("the backfill finished overnight", at: 0.2) + spoken("Great, post the numbers please", at: 3)
        let lines = TranscriptBuilder.transcript(mine: mine, others: others, turns: [SpeakerTurn(speaker: "S1", start: 0, end: 2)])
        #expect(lines.map(\.label) == ["S1", "me"])
        #expect(lines.map(\.text) == ["the backfill finished overnight", "Great, post the numbers please"])
        // A short answer over someone else is yours.
        let theirs = TranscriptBuilder.Line(label: "S1", start: 0, end: 2, text: "Is it ready, yes or no?")
        #expect(!TranscriptBuilder.isEcho(.init(label: "me", start: 1, end: 1.3, text: "Yes."), of: theirs))
    }

    @Test func voicesMatchSavedOnesOncePerName() {
        let ada: [Float] = [1, 0, 0], grace: [Float] = [0, 1, 0]
        let matches = VoiceMatcher.match(["S1": [0.9, 0.1, 0], "S2": [0.95, 0.05, 0], "S3": [0, 0, 1], "S4": [0.1, 0.9, 0]],
                                         against: [("Ada", ada), ("Grace", grace)])
        #expect(matches == ["S2": "Ada", "S4": "Grace"])
        #expect(VoiceMatcher.similarity([1, 0], [1, 0]) == 1)
        #expect(VoiceMatcher.similarity([1, 0], [1, 0, 0]) == 0)
    }

    @Test func voiceprintsRoundTripAndAverage() {
        let profile = VoiceProfile(name: "Ada", voiceprint: [1, 0, 2])
        #expect(profile.voiceprint == [1, 0, 2])
        profile.add([3, 2, 0])
        #expect(profile.voiceprint == [2, 1, 1] && profile.meetings == 2)
        profile.add([1])
        #expect(profile.voiceprint == [1] && profile.meetings == 1)
    }
}

@MainActor
struct FinalTranscriptTests {
    /// A meeting with two live lines and a recording file (empty: tracks are faked).
    func recordedMeeting(_ zoom: ZoomExtension, _ host: FakeHost, engine: FakeSpeechEngine) throws -> MeetingRecord {
        let file = FileManager.default.temporaryDirectory.appending(path: "final-transcript-\(UUID().uuidString).m4a")
        try Data().write(to: file)
        let meeting = insertMeeting(host, title: "Sync", startedAt: Date(timeIntervalSince1970: 1_000_000),
                                    lines: [(1, "Sadik", "Morning."), (4, "Others", "i check the index")])
        meeting.participants = ["Ada Lovelace", "Grace Hopper"]
        meeting.recordingPath = file.path
        zoom.speechEngine = engine
        zoom.readTracks = { _ in [[0, 0], [1, 1]] }
        return meeting
    }

    static let engine = FakeSpeechEngine(
        zoom: spoken("Is the migration ready?", at: 3) + spoken("Almost, I check the indexes.", at: 6),
        mic: spoken("Morning everyone", at: 0.5),
        diarization: Diarization(turns: [SpeakerTurn(speaker: "S1", start: 3, end: 5), SpeakerTurn(speaker: "S2", start: 6, end: 9)],
                                 voiceprints: ["S1": [1, 0, 0], "S2": [0, 1, 0]]))

    @Test func theRecordingReplacesTheLiveLines() async throws {
        let (zoom, host) = makeZoom()
        let meeting = try recordedMeeting(zoom, host, engine: Self.engine)
        try await zoom.improveTranscript(meeting)

        #expect(meeting.improvedAt != nil && zoom.improving == nil)
        let lines = zoom.namedSegments(meeting.id)
        #expect(lines.map(\.speaker) == ["Sadik", "Speaker 1", "Speaker 2"])
        #expect(lines.map(\.text) == ["Morning everyone", "Is the migration ready?", "Almost, I check the indexes."])
        #expect(lines[1].createdAt == meeting.startedAt.addingTimeInterval(3))
        #expect(zoom.segments(meeting.id).filter { $0.source == "live" }.count == 2)
        #expect(zoom.meetingSpeakers(meeting.id).map(\.label) == ["me", "S1", "S2"])
        #expect(zoom.speakers(meeting.id).map(\.name) == ["Sadik", "Speaker 1", "Speaker 2"])
        #expect(host.fakePermissions.asked.isEmpty)

        // Again: the final lines are replaced, not added.
        try await zoom.improveTranscript(meeting)
        #expect(zoom.namedSegments(meeting.id).count == 3 && zoom.meetingSpeakers(meeting.id).count == 3)
    }

    @Test func aNamedVoiceIsRecognisedInTheNextMeeting() async throws {
        let (zoom, host) = makeZoom()
        let first = try recordedMeeting(zoom, host, engine: Self.engine)
        try await zoom.improveTranscript(first)
        zoom.rename("S2", in: first.id, to: "Grace Hopper")
        #expect(zoom.namedSegments(first.id).map(\.speaker) == ["Sadik", "Speaker 1", "Grace Hopper"])
        #expect(zoom.meetingSpeakers(first.id).first { $0.label == "S2" }?.nameSource == "user")

        var engine = Self.engine
        engine.diarization = Diarization(turns: Self.engine.diarization.turns, voiceprints: ["S1": [0.1, 0.9, 0], "S2": [0, 0, 1]])
        let second = try recordedMeeting(zoom, host, engine: engine)
        try await zoom.improveTranscript(second)
        #expect(zoom.namedSegments(second.id).map(\.speaker) == ["Sadik", "Grace Hopper", "Speaker 2"])
        #expect(zoom.meetingSpeakers(second.id).first { $0.label == "S1" }?.nameSource == "voice")

        zoom.rename("S1", in: second.id, to: "Grace Hopper")
        let profiles = try host.context.fetch(FetchDescriptor<VoiceProfile>())
        #expect(profiles.map(\.name) == ["Grace Hopper"] && profiles.first?.meetings == 2)
        #expect(zoom.savedVoices == ["Grace Hopper"])
        zoom.forgetVoices()
        #expect(zoom.savedVoices.isEmpty)
    }

    @Test func dashiiNamesUnnamedVoicesAsGuesses() async throws {
        let (zoom, host) = makeZoom()
        let meeting = try recordedMeeting(zoom, host, engine: Self.engine)
        try await zoom.improveTranscript(meeting)
        zoom.rename("S1", in: meeting.id, to: "Ada Lovelace")
        host.fakeDashii.response = """
            {"title":"Release sync","summary":"Migration status.","people":[],"topics":[],"decisions":[],"risks":[],"action_items":[],"speakers":[],
             "voices":[{"speaker":"Speaker 2","name":"Grace Hopper"},{"speaker":"Ada Lovelace","name":"Someone"},{"speaker":"Speaker 9","name":"Nobody"}]}
            """
        try await zoom.summarize(meeting)

        let prompt = try #require(host.fakeDashii.prompts.first)
        #expect(prompt.contains("\"Speaker 1\", \"Speaker 2\"… are voices not named yet"))
        #expect(prompt.contains("[2] [00:06] Speaker 2: Almost, I check the indexes."))
        #expect(!prompt.contains("i check the index"))
        #expect(zoom.namedSegments(meeting.id).map(\.speaker) == ["Sadik", "Ada Lovelace", "Grace Hopper"])
        #expect(zoom.guessedLabels(meeting.id) == ["S2"])
        let text = ZoomExtension.transcriptText(zoom.namedSegments(meeting.id), since: meeting.startedAt, guessed: zoom.guessedLabels(meeting.id))
        #expect(text.contains("Grace Hopper (guessed): Almost") && text.contains("Ada Lovelace: Is the"))
    }

    @Test func theFirstPassAsksBeforeDownloading() async throws {
        let (zoom, host) = makeZoom()
        var engine = Self.engine
        engine.ready = false
        let meeting = try recordedMeeting(zoom, host, engine: engine)
        try await zoom.improveTranscript(meeting, automatically: true)
        #expect(host.fakePermissions.asked == ["Download the speech models?"])
        #expect(meeting.improvedAt == nil && !zoom.improveAfterMeeting)
        #expect(zoom.namedSegments(meeting.id).map(\.text) == ["Morning.", "i check the index"])
    }

    @Test func withoutARecordingThereIsNothingToImprove() async throws {
        let (zoom, host) = makeZoom()
        let meeting = insertMeeting(host, title: "Sync", startedAt: .now)
        await #expect(throws: ToolError.self) { try await zoom.improveTranscript(meeting) }
    }

    @Test func audioNotKeptIsRecordedToATemporaryFile() {
        let (zoom, host) = makeZoom()
        defer { _ = host }
        zoom.saveAudio = false
        #expect(zoom.recordingOptions?.folder == ZoomExtension.temporaryRecordings)
        #expect(zoom.recordingOptions?.video == false)
        zoom.improveAfterMeeting = false
        #expect(zoom.recordingOptions == nil)
        zoom.saveAudio = true
        #expect(zoom.recordingOptions?.folder == zoom.recordingsFolder)
    }
}
