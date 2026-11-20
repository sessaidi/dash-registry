import DashKit
import Foundation
import MeetingSpeech
import SwiftData

/// The final transcript: after the meeting, the recording is transcribed again on this Mac with
/// stronger models than the live one (your quiet microphone included, French and English mixed),
/// Zoom's audio is split into voices, and the voices get names: from voices you named in earlier
/// meetings, then Dashii's guesses from what was said (`summarize`), then yours in the sheet.
extension ZoomExtension {
    struct ImproveProgress: Equatable {
        let meetingID: UUID
        var step: String
        var fraction: Double?
    }

    /// Where the audio of a meeting goes when it isn't kept: deleted after the final transcript.
    static var temporaryRecordings: URL { FileManager.default.temporaryDirectory.appending(path: "Dash Meetings") }

    func meetingSpeakers(_ meetingID: UUID) -> [MeetingSpeaker] {
        let descriptor = FetchDescriptor<MeetingSpeaker>(predicate: #Predicate { $0.meetingID == meetingID })
        return ((try? host?.context.fetch(descriptor)) ?? []).sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// The voices whose names are Dashii's guesses.
    func guessedLabels(_ meetingID: UUID) -> Set<String> {
        Set(meetingSpeakers(meetingID).filter(\.isGuess).map(\.label))
    }

    /// Transcribes `audio` (default: the meeting's recording) again and replaces the live lines
    /// with the final ones. The first time, asks before downloading the models.
    func improveTranscript(_ meeting: MeetingRecord, audio: URL? = nil, automatically: Bool = false) async throws {
        guard host != nil, improving == nil else { return }
        guard let url = audio ?? meeting.recordingPath.map({ URL(filePath: $0) }), FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("This meeting has no recording to transcribe.")
        }
        guard await ensureSpeechModels(automatically: automatically) else { return }
        let meetingID = meeting.id
        improving = ImproveProgress(meetingID: meetingID, step: "Loading the speech models")
        defer { improving = nil }
        let engine = speechEngine
        try await engine.prepare { [weak self] fraction in
            Task { @MainActor in
                guard let self, fraction < 1, self.improving?.meetingID == meetingID else { return }
                self.improving = ImproveProgress(meetingID: meetingID, step: "Downloading the speech models", fraction: fraction)
            }
        }
        improving = ImproveProgress(meetingID: meetingID, step: "Transcribing the recording")
        let tracks = try await readTracks(url)
        guard let zoomAudio = tracks.first else { throw ToolError("The recording has no audio.") }
        let others = try await engine.transcribe(zoomAudio)
        let mine = tracks.count > 1 ? try await engine.transcribe(tracks[1]) : []
        improving = ImproveProgress(meetingID: meetingID, step: "Separating the voices")
        let diarization = try await engine.diarize(zoomAudio)
        apply(TranscriptBuilder.transcript(mine: mine, others: others, turns: diarization.turns), diarization: diarization, to: meeting)
    }

    /// Stores a final transcript: earlier final lines and speakers go, live lines are kept as
    /// "live", voices you named before are recognised.
    func apply(_ lines: [TranscriptBuilder.Line], diarization: Diarization, to meeting: MeetingRecord) {
        guard let host else { return }
        let meetingID = meeting.id
        for segment in segments(meetingID) {
            switch segment.source {
            case "final": host.context.delete(segment)
            case "audio", "inferred": segment.source = "live"
            default: break
            }
        }
        for speaker in meetingSpeakers(meetingID) { host.context.delete(speaker) }

        let voices = TranscriptBuilder.voices(lines)
        let saved = ((try? host.context.fetch(FetchDescriptor<VoiceProfile>())) ?? []).map { (name: $0.name, voiceprint: $0.voiceprint) }
        let recognised = VoiceMatcher.match(diarization.voiceprints.filter { voices.contains($0.key) }, against: saved.filter { $0.name != myName })
        var names = [TranscriptBuilder.me: myName, "": MeetingRecorder.othersSpeaker]
        let mine = lines.filter { $0.label == TranscriptBuilder.me }
        if !mine.isEmpty {
            host.context.insert(MeetingSpeaker(meetingID: meetingID, label: TranscriptBuilder.me, name: myName, nameSource: "me",
                                               seconds: mine.reduce(0) { $0 + $1.end - $1.start }))
        }
        for (index, label) in voices.enumerated() {
            let name = recognised[label]
            names[label] = name ?? Self.unnamedVoice(index)
            let seconds = diarization.turns.filter { $0.speaker == label }.reduce(0) { $0 + $1.end - $1.start }
            host.context.insert(MeetingSpeaker(meetingID: meetingID, label: label, name: name ?? "", nameSource: name == nil ? "" : "voice",
                                               seconds: seconds, voiceprint: diarization.voiceprints[label] ?? []))
        }
        for line in lines {
            let segment = TranscriptSegment(meetingID: meetingID, speaker: names[line.label] ?? MeetingRecorder.othersSpeaker, text: line.text, source: "final")
            segment.speakerLabel = line.label
            segment.createdAt = meeting.startedAt.addingTimeInterval(line.start)
            host.context.insert(segment)
        }
        meeting.improvedAt = .now
        try? host.context.save()
    }

    /// "Speaker 1", "Speaker 2"… in the order the voices first speak.
    static func unnamedVoice(_ index: Int) -> String { "Speaker \(index + 1)" }

    /// Names a voice of a meeting: its lines, and (for Zoom's voices) the saved voice later
    /// meetings recognise.
    func rename(_ label: String, in meetingID: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host, !name.isEmpty, let speaker = meetingSpeakers(meetingID).first(where: { $0.label == label }) else { return }
        speaker.name = name
        speaker.nameSource = label == TranscriptBuilder.me ? "me" : "user"
        for segment in segments(meetingID) where segment.source == "final" && segment.speakerLabel == label { segment.speaker = name }
        let voiceprint = speaker.voiceprint
        if label != TranscriptBuilder.me, !voiceprint.isEmpty {
            let profile = try? host.context.fetch(FetchDescriptor<VoiceProfile>(predicate: #Predicate { $0.name == name })).first
            if let profile { profile.add(voiceprint) } else { host.context.insert(VoiceProfile(name: name, voiceprint: voiceprint)) }
        }
        try? host.context.save()
    }

    /// The names of the voices later meetings recognise.
    var savedVoices: [String] {
        ((try? host?.context.fetch(FetchDescriptor<VoiceProfile>(sortBy: [SortDescriptor(\.name)]))) ?? []).map(\.name)
    }

    func forgetVoices() {
        guard let host else { return }
        try? host.context.delete(model: VoiceProfile.self)
        try? host.context.save()
    }

    /// Applies Dashii's guesses for voices nobody named yet ("Speaker 2" → a participant).
    func applyVoiceGuesses(_ guesses: [JSONValue], to meetingID: UUID) {
        let speakers = meetingSpeakers(meetingID)
        let segments = segments(meetingID).filter { $0.source == "final" }
        var taken = Set(speakers.map(\.name).filter { !$0.isEmpty })
        for guess in guesses {
            guard let voice = guess["speaker"]?.string, let name = guess["name"]?.string?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  !taken.contains(name) else { continue }
            guard let speaker = speakers.first(where: { $0.name.isEmpty && voice == displayName(of: $0, among: segments) }) else { continue }
            speaker.name = name
            speaker.nameSource = "guess"
            taken.insert(name)
            for segment in segments where segment.speakerLabel == speaker.label { segment.speaker = name }
        }
    }

    /// The name a voice's lines show.
    private func displayName(of speaker: MeetingSpeaker, among segments: [TranscriptSegment]) -> String {
        speaker.name.isEmpty ? segments.first { $0.speakerLabel == speaker.label }?.speaker ?? "" : speaker.name
    }

    /// The models are here, or the user agreed to download them. Declining an automatic pass
    /// turns the pass off (Settings turns it back on).
    private func ensureSpeechModels(automatically: Bool) async -> Bool {
        guard let host else { return false }
        guard !speechEngine.isReady, !defaults.bool(forKey: "zoom.speechModelsAccepted") else { return true }
        let proceed = await host.permissions.ask(
            icon: "waveform.badge.magnifyingglass", title: "Download the speech models?",
            message: "To transcribe meetings again once they end, with each voice apart, Dash downloads two on-device models once (\(Self.speechModelsSize), from Hugging Face). Audio never leaves this Mac.",
            allowLabel: "Download", denyLabel: "Not Now")
        if proceed { defaults.set(true, forKey: "zoom.speechModelsAccepted") } else if automatically { improveAfterMeeting = false }
        return proceed
    }

    static let speechModelsSize = "about 630 MB"
}
