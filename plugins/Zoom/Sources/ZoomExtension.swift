import AppKit
import AVFoundation
import CoreGraphics
import DashKit
import Foundation
import Observation
import SwiftData
import SwiftUI

/// Local Zoom meeting transcription: Zoom's audio and your microphone are transcribed on this Mac,
/// participants are read from Zoom's window through Accessibility, and Claude summarises the result.
@MainActor
@Observable
final class ZoomExtension: DashExtension {
    let id = "zoom"
    let name = "Zoom"
    let systemImage = "video"
    let metadata = ExtensionMetadata(
        version: "1.3.0", author: .dash, summary: "On-device Zoom transcripts, participants, summaries and recordings.",
        category: .communication, tags: ["zoom", "meetings", "transcription"], homepage: "https://github.com/sessaidi/dash-extensions",
        minimumDashKit: "1.0.0")

    // Preference keys are the built-in extension's ("zoom.myName", …) so existing settings carry over.
    var myName: String { didSet { defaults.set(myName, forKey: "zoom.myName") } }
    var localeIdentifier: String { didSet { defaults.set(localeIdentifier, forKey: "zoom.locale") } }
    var autoStart: Bool { didSet { defaults.set(autoStart, forKey: "zoom.autoStart") } }
    var summarizeOnStop: Bool { didSet { defaults.set(summarizeOnStop, forKey: "zoom.summarize") } }
    /// Save the meeting's audio (Zoom and your microphone) to a file.
    var saveAudio: Bool { didSet { defaults.set(saveAudio, forKey: "zoom.saveAudio") } }
    /// Also record Zoom's windows as video (the file becomes a .mov). Needs `saveAudio`.
    var recordVideo: Bool { didSet { defaults.set(recordVideo, forKey: "zoom.recordVideo") } }
    var recordingsFolder: URL { didSet { defaults.set(recordingsFolder.path, forKey: "zoom.recordingsFolder") } }

    static var defaultRecordingsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Dash Meetings") }
    /// What the next meeting saves to disk, if anything.
    var recordingOptions: MeetingRecorder.Recording? {
        saveAudio ? MeetingRecorder.Recording(folder: recordingsFolder, startedAt: .now, video: recordVideo) : nil
    }

    private(set) var isZoomRunning = false
    private(set) var inMeeting = false
    private(set) var isRecording = false
    private(set) var currentMeetingID: UUID?
    @ObservationIgnored var seenCaptions = Set<String>()
    /// Live participant list from Zoom's Participants panel.
    private(set) var participants: [String] = []
    private(set) var lastError: String?
    private(set) var isSummarizing = false

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var recorder: MeetingRecorder?
    @ObservationIgnored private var missedMeetingChecks = 0

    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
        myName = defaults.string(forKey: "zoom.myName") ?? NSFullUserName()
        localeIdentifier = defaults.string(forKey: "zoom.locale") ?? Locale.current.identifier
        autoStart = defaults.object(forKey: "zoom.autoStart") as? Bool ?? false
        summarizeOnStop = defaults.object(forKey: "zoom.summarize") as? Bool ?? true
        saveAudio = defaults.object(forKey: "zoom.saveAudio") as? Bool ?? true
        recordVideo = defaults.bool(forKey: "zoom.recordVideo")
        recordingsFolder = defaults.string(forKey: "zoom.recordingsFolder").map { URL(filePath: $0) } ?? Self.defaultRecordingsFolder
    }

    var models: [any PersistentModel.Type] { [MeetingRecord.self, TranscriptSegment.self] }
    var widgets: [WidgetType] { [WidgetType(MeetingWidget.self)] }
    func settingsView() -> AnyView { AnyView(ZoomSettingsView(zoom: self)) }

    func start(host: any ExtensionContext) {
        attach(host)
        monitor?.cancel()
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Binds the host without polling Zoom (what `start` does first; tests use it alone).
    func attach(_ host: any ExtensionContext) {
        self.host = host
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        if isRecording { Task { await stopRecording() } }
    }

    private func poll() {
        isZoomRunning = ZoomAccessibility.isZoomRunning
        guard isZoomRunning, ZoomAccessibility.isTrusted else {
            inMeeting = false
            return
        }
        let inMeeting = ZoomAccessibility.isInMeeting
        observe(inMeeting: inMeeting, participants: inMeeting ? ZoomAccessibility.participants() : [])
        if inMeeting, isRecording, let meetingID = currentMeetingID { addCaptions(ZoomAccessibility.captionLines(), to: meetingID) }
    }

    /// Applies one reading of Zoom's windows: the live participants, the current meeting's
    /// participant list, auto-start, and stopping once the meeting window has gone.
    func observe(inMeeting: Bool, participants names: [String]) {
        self.inMeeting = inMeeting
        if inMeeting {
            missedMeetingChecks = 0
            if names != participants { participants = names }
            if let meeting = currentMeeting {
                let union = MeetingRecord.merged(meeting.participants, names)
                if union != meeting.participants { meeting.participants = union }
            }
            if autoStart, !isRecording { Task { await startRecording() } }
        } else if isRecording {
            // Two misses in a row (10 s) means the meeting window closed.
            missedMeetingChecks += 1
            if missedMeetingChecks >= 2 { Task { await stopRecording() } }
        }
    }

    var currentMeeting: MeetingRecord? {
        guard let currentMeetingID else { return nil }
        return meeting(currentMeetingID)
    }

    func meeting(_ id: UUID) -> MeetingRecord? {
        try? host?.context.fetch(FetchDescriptor<MeetingRecord>(predicate: #Predicate { $0.id == id })).first
    }

    func segments(_ meetingID: UUID) -> [TranscriptSegment] {
        let descriptor = FetchDescriptor<TranscriptSegment>(predicate: #Predicate { $0.meetingID == meetingID }, sortBy: [SortDescriptor(\.createdAt)])
        return (try? host?.context.fetch(descriptor)) ?? []
    }

    /// Explains and requests the macOS permissions recording needs. Returns false if capture can't start.
    /// The usage strings macOS shows (microphone, speech, screen capture) are Dash.app's: plugins run in its process.
    private func ensurePermissions() async -> Bool {
        guard let host else { return false }
        if !CGPreflightScreenCaptureAccess() {
            let proceed = await host.permissions.ask(
                icon: "record.circle", title: "Allow Dash to capture Zoom's audio",
                message: "macOS needs Screen & System Audio Recording permission so Dash can hear the meeting. Audio is transcribed on this Mac. After granting it, quit and reopen Dash.",
                allowLabel: "Open Settings", denyLabel: "Not Now")
            if proceed {
                CGRequestScreenCaptureAccess()
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            return false
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            let proceed = await host.permissions.ask(
                icon: "mic", title: "Transcribe your microphone too?",
                message: "With microphone access, your own lines are labelled with your name instead of being mixed into “Others”.",
                allowLabel: "Continue", denyLabel: "Skip")
            if proceed { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        }
        if !ZoomAccessibility.isTrusted, !defaults.bool(forKey: "zoom.askedAccessibility") {
            defaults.set(true, forKey: "zoom.askedAccessibility")
            let proceed = await host.permissions.ask(
                icon: "person.2", title: "See who is in the meeting?",
                message: "Accessibility access lets Dash read Zoom's meeting window and Participants panel to list who is online.",
                allowLabel: "Open Settings", denyLabel: "Skip")
            if proceed { ZoomAccessibility.requestTrust() }
        }
        return true
    }

    func startRecording() async {
        guard host != nil, !isRecording else { return }
        guard await ensurePermissions() else { return }
        guard let meetingID = beginMeeting() else { return }
        let recorder = MeetingRecorder(
            onSegment: { [weak self] segment in
                Task { @MainActor in self?.add(segment, to: meetingID) }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.lastError = error.localizedDescription
                    await self?.stopRecording()
                }
            })
        self.recorder = recorder
        do {
            try await recorder.start(locale: Locale(identifier: localeIdentifier), myName: myName, recording: recordingOptions)
        } catch {
            lastError = error.localizedDescription
            await stopRecording()
        }
    }

    /// Opens the record of a new meeting with the live participants and marks recording on.
    /// `startRecording` then attaches the audio capture.
    @discardableResult
    func beginMeeting() -> UUID? {
        guard let host, !isRecording else { return nil }
        isRecording = true
        lastError = nil
        let meeting = MeetingRecord(title: "Zoom meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))")
        meeting.participants = participants
        host.context.insert(meeting)
        try? host.context.save()
        currentMeetingID = meeting.id
        seenCaptions = []
        host.emit("meeting.started", from: self, title: saveAudio ? "Recording a Zoom meeting" : "Transcribing a Zoom meeting", detail: participants.joined(separator: ", "), importance: .notable)
        return meeting.id
    }

    func stopRecording() async {
        guard isRecording else { return }
        isRecording = false
        let file = await recorder?.stop()
        recorder = nil
        guard let meeting = currentMeeting else { return }
        currentMeetingID = nil
        meeting.endedAt = .now
        meeting.recordingPath = file?.path
        host?.emit("meeting.ended", from: self, title: "Meeting ended: \(meeting.title)",
                   detail: "\(meeting.participants.count) participants" + (file.map { ", saved to \($0.lastPathComponent)" } ?? ""), importance: .notable)
        try? host?.context.save()
        if segments(meeting.id).isEmpty, file == nil {
            host?.context.delete(meeting)
            try? host?.context.save()
        } else if summarizeOnStop {
            try? await summarize(meeting)
        }
    }

    /// Stores caption lines not seen yet (Zoom keeps the whole list on screen).
    func addCaptions(_ lines: [(speaker: String, text: String)], to meetingID: UUID) {
        guard let host else { return }
        var added = false
        for line in lines {
            let key = "\(line.speaker)|\(line.text)"
            guard seenCaptions.insert(key).inserted else { continue }
            host.context.insert(TranscriptSegment(meetingID: meetingID, speaker: line.speaker, text: line.text, source: "captions"))
            added = true
        }
        if added { try? host.context.save() }
    }

    /// The transcript with names: the user's own lines plus Zoom's captions, when captions were
    /// on (they replace the anonymous "Others" audio); otherwise everything.
    func namedSegments(_ meetingID: UUID) -> [TranscriptSegment] {
        let all = segments(meetingID)
        guard all.contains(where: { $0.source == "captions" }) else { return all }
        return all.filter { $0.source == "captions" || $0.speaker != MeetingRecorder.othersSpeaker }
    }

    /// Who spoke, in order of first words, with how much they said (from named captions).
    func speakers(_ meetingID: UUID) -> [(name: String, first: Date, last: Date, lines: Int, words: Int)] {
        var result: [String: (first: Date, last: Date, lines: Int, words: Int)] = [:]
        var order: [String] = []
        for segment in segments(meetingID) where segment.source == "captions" || segment.speaker == myName {
            if result[segment.speaker] == nil { order.append(segment.speaker) }
            let words = segment.text.split(separator: " ").count
            let current = result[segment.speaker]
            result[segment.speaker] = (current?.first ?? segment.createdAt, segment.createdAt, (current?.lines ?? 0) + 1, (current?.words ?? 0) + words)
        }
        return order.compactMap { name in result[name].map { (name, $0.first, $0.last, $0.lines, $0.words) } }
    }

    func add(_ segment: MeetingRecorder.Segment, to meetingID: UUID) {
        host?.context.insert(TranscriptSegment(meetingID: meetingID, speaker: segment.speaker, text: segment.text))
        try? host?.context.save()
    }

    static func transcriptText(_ segments: [TranscriptSegment], since start: Date) -> String {
        segments.map { segment in
            let offset = Int(segment.createdAt.timeIntervalSince(start))
            return String(format: "[%02d:%02d] %@: %@", offset / 60, offset % 60, segment.speaker, segment.text)
        }.joined(separator: "\n")
    }

    static let summarySchema: JSONValue = [
        "type": "object", "additionalProperties": false,
        "required": ["title", "summary", "decisions", "action_items"],
        "properties": [
            "title": ["type": "string", "description": "Short meeting title from its content."],
            "summary": ["type": "string", "description": "One paragraph."],
            "decisions": ["type": "array", "items": ["type": "string"]],
            "action_items": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false, "required": ["owner", "task"],
                    "properties": ["owner": ["type": "string"], "task": ["type": "string"]],
                ],
            ],
        ],
    ]

    func summarize(_ meeting: MeetingRecord) async throws {
        guard let host else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        let transcript = Self.transcriptText(segments(meeting.id), since: meeting.startedAt)
        let prompt = """
            Participants seen in Zoom: \(meeting.participants.joined(separator: ", "))
            Lines from "\(myName)" are the user's microphone; "\(MeetingRecorder.othersSpeaker)" is everyone else's audio mixed together, \
            so attribute those lines to a person only when the transcript makes it clear.

            <transcript>
            \(transcript)
            </transcript>
            """
        let text = try await host.dashii.complete(
            system: "You summarise work meetings for an engineer: what was discussed, what was decided, and who owes what.",
            prompt: prompt, outputSchema: Self.summarySchema, effort: "low")
        let result = try JSONValue.parse(text)
        meeting.title = result["title"]?.string ?? meeting.title
        meeting.summary = result["summary"]?.string ?? ""
        meeting.decisions = result["decisions"]?.array?.compactMap(\.string) ?? []
        meeting.actionItems = (try? result["action_items"]?.decode([MeetingRecord.ActionItem].self)) ?? []
        host.emit("meeting.summarized", from: self, title: "Summary ready: \(meeting.title)",
                  detail: "\(meeting.decisions.count) decisions, \(meeting.actionItems.count) action items", importance: .notable)
        try? host.context.save()
    }

    // MARK: Claude tools

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
            DashiiTool(name: "meetings_list", description: "List recorded meetings, newest first, with their summaries and action items.") { [weak self] _ in
                guard let self, let host else { return [] }
                var descriptor = FetchDescriptor<MeetingRecord>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
                descriptor.fetchLimit = 30
                return .array(((try? host.context.fetch(descriptor)) ?? []).map(\.json))
            },
            DashiiTool(
                name: "meeting_transcript",
                description: "Read a meeting's transcript. With Zoom's captions on, each line has the participant's name; otherwise lines are the user (microphone) or \"Others\" (everyone else).",
                properties: ["meeting_id": JSONSchema.string("Meeting id, or \"current\". Defaults to the current or latest meeting.")]
            ) { [weak self] input in
                guard let self else { return nil }
                let meeting = try resolve(try input.toolInput(MeetingInput.self).meeting_id)
                return meeting.json.merging(["transcript": .string(Self.transcriptText(namedSegments(meeting.id), since: meeting.startedAt))])
            },
            DashiiTool(
                name: "meeting_speakers",
                description: "Who spoke in a meeting, in the order they first spoke, with when, how many lines and words, and who is speaking now. Names come from Zoom's captions (turn on captions or the live transcript in Zoom); without them only the user is named.",
                properties: ["meeting_id": JSONSchema.string("Meeting id, or \"current\". Defaults to the current or latest meeting.")]
            ) { [weak self] input in
                guard let self else { return nil }
                let meeting = try resolve(try input.toolInput(MeetingInput.self).meeting_id)
                let speakers = speakers(meeting.id)
                let latest = segments(meeting.id).last { $0.source == "captions" || $0.speaker == myName }
                return ["meeting_id": .string(meeting.id.uuidString), "participants": .array(meeting.participants.map { .string($0) }),
                        "named": .bool(segments(meeting.id).contains { $0.source == "captions" }),
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

private struct ZoomSettingsView: View {
    @Bindable var zoom: ZoomExtension

    var body: some View {
        Form {
            Section("Transcription") {
                TextField("Your name", text: $zoom.myName)
                TextField("Language", text: $zoom.localeIdentifier, prompt: Text("en_US"))
                Toggle("Start transcribing when a Zoom meeting starts", isOn: $zoom.autoStart)
                Toggle("Summarise with Claude when the meeting ends", isOn: $zoom.summarizeOnStop)
            }
            Section {
                Toggle("Save the meeting's audio", isOn: $zoom.saveAudio)
                Toggle("Also record video of Zoom's windows", isOn: $zoom.recordVideo)
                    .disabled(!zoom.saveAudio)
                LabeledContent("Folder") {
                    HStack {
                        Text(zoom.recordingsFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        Button("Show") {
                            try? FileManager.default.createDirectory(at: zoom.recordingsFolder, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(zoom.recordingsFolder)
                        }
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Audio is saved as an .m4a with two tracks, Zoom and your microphone. With video it is a .mov of Zoom's windows on the screen showing the meeting (other apps are left out), at up to 1920 pixels and 15 frames a second. Files stay on this Mac.")
            }
            Section {
                LabeledContent("Accessibility") {
                    if ZoomAccessibility.isTrusted { Text("Granted").foregroundStyle(.green) } else {
                        Button("Grant…") { ZoomAccessibility.requestTrust() }
                    }
                }
                LabeledContent("Screen & system audio recording") {
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Accessibility reads Zoom's meeting window and Participants panel. Screen recording permission lets Dash capture Zoom's audio and windows. Speech is transcribed on this Mac; the transcript goes to Claude only when summarising or when you ask about it.")
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = zoom.recordingsFolder
        if panel.runModal() == .OK, let url = panel.url { zoom.recordingsFolder = url }
    }
}
