import AppKit
import AVFoundation
import CoreGraphics
import DashKit
import Foundation
import MeetingSpeech
import Observation
import SwiftData
import SwiftUI

/// Meetings (Zoom): Zoom's audio and your microphone are transcribed on this Mac live, then again
/// from the recording with each voice apart; participants are read from Zoom's window through
/// Accessibility, and Claude summarises the result.
@MainActor
@Observable
final class ZoomExtension: DashExtension {
    let id = "zoom"
    let name = "Meetings"
    let systemImage = "video"
    let metadata = ExtensionMetadata(
        version: "1.10.1", author: .dash, summary: "On-device Zoom transcripts with each voice named, participants, summaries and recordings.",
        category: .communication, tags: ["zoom", "meetings", "transcription"], homepage: "https://github.com/sessaidi/dash-extensions",
        minimumDashKit: "2.0.0")

    // Preference keys are the built-in extension's ("zoom.myName", …) so existing settings carry over.
    var myName: String { didSet { defaults.set(myName, forKey: "zoom.myName") } }
    var localeIdentifier: String { didSet { defaults.set(localeIdentifier, forKey: "zoom.locale") } }
    /// Record as soon as you're in a Zoom meeting (on unless turned off; "zoom.autoRecord"
    /// replaced the older, off-by-default "zoom.autoStart").
    var autoStart: Bool { didSet { defaults.set(autoStart, forKey: "zoom.autoRecord") } }
    /// Open Zoom's transcript panel when a recording starts: its lines carry each speaker's name.
    var openTranscript: Bool { didSet { defaults.set(openTranscript, forKey: "zoom.openTranscript") } }
    var summarizeOnStop: Bool { didSet { defaults.set(summarizeOnStop, forKey: "zoom.summarize") } }
    /// Save the meeting's audio (Zoom and your microphone) to a file.
    var saveAudio: Bool { didSet { defaults.set(saveAudio, forKey: "zoom.saveAudio") } }
    /// Transcribe the recording again when the meeting ends, each voice apart (`improveTranscript`).
    var improveAfterMeeting: Bool { didSet { defaults.set(improveAfterMeeting, forKey: "zoom.improve") } }
    /// Also record Zoom's windows as video (the file becomes a .mov). Needs `saveAudio`.
    var recordVideo: Bool { didSet { defaults.set(recordVideo, forKey: "zoom.recordVideo") } }
    var recordingsFolder: URL { didSet { defaults.set(recordingsFolder.path, forKey: "zoom.recordingsFolder") } }
    /// Read upcoming Zoom meetings from the Mac's calendars.
    var useCalendar: Bool { didSet { defaults.set(useCalendar, forKey: "zoom.calendar"); refreshCalendar() } }
    /// Minutes before a meeting that `zoom.meeting_soon` fires.
    var reminderMinutes: Int { didSet { defaults.set(reminderMinutes, forKey: "zoom.reminderMinutes") } }

    static var defaultRecordingsFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies/Dash Meetings") }
    /// What the next meeting saves to disk, if anything.
    var recordingOptions: MeetingRecorder.Recording? {
        if saveAudio { return MeetingRecorder.Recording(folder: recordingsFolder, startedAt: .now, video: recordVideo) }
        return improveAfterMeeting ? MeetingRecorder.Recording(folder: Self.temporaryRecordings, startedAt: .now, video: false) : nil
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
    /// The final transcript being made, and how far it got.
    var improving: ImproveProgress?
    @ObservationIgnored var speechEngine: any SpeechEngine = FluidSpeechEngine()
    @ObservationIgnored var readTracks: @Sendable (URL) async throws -> [[Float]] = { try await MeetingAudio.tracks(of: $0) }
    /// The next 24 hours of calendar events with a Zoom link (empty without the calendar).
    var upcoming: [CalendarMeeting] = []
    private(set) var calendarAccess: ZoomCalendar.Access = .notAsked

    @ObservationIgnored private(set) weak var host: (any ExtensionContext)?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var recorder: MeetingRecorder?
    @ObservationIgnored private var missedMeetingChecks = 0
    /// Started by "Start transcribing when a Zoom meeting starts": it also stops by itself.
    /// A recording the user started stops only when they press Stop or Zoom quits.
    @ObservationIgnored private(set) var startedAutomatically = false
    @ObservationIgnored private var zoomGoneChecks = 0
    /// Stopped during a meeting (by you, or a failure): don't record it again by itself until
    /// the meeting is over.
    @ObservationIgnored private(set) var autoStartHeld = false
    @ObservationIgnored private var outOfMeetingChecks = 0
    /// A start is checking permissions: every poll during a meeting would start (and prompt) again.
    @ObservationIgnored private var isStarting = false
    /// The screen recording prompt was shown since launch: automatic starts don't show it again
    /// (a grant only takes effect after Dash relaunches).
    @ObservationIgnored private var askedScreenCapture = false
    /// Checks left to try opening Zoom's transcript panel in the current recording.
    @ObservationIgnored private var transcriptTries = 0
    /// Why the last recording stopped, shown in the widget and logged.
    private(set) var lastStopReason: String?
    /// Checks (5 s each) without any sign of the meeting before an automatic recording stops: 2 minutes.
    static let autoStopChecks = 24
    @ObservationIgnored let calendar = ZoomCalendar()
    @ObservationIgnored private var calendarObserver: NSObjectProtocol?
    /// Calendar meetings `zoom.meeting_soon` already fired for.
    @ObservationIgnored private var reminded = Set<String>()
    /// Meetings named after their calendar event: the summary keeps that name.
    @ObservationIgnored private var namedFromCalendar = Set<UUID>()

    init(defaults: UserDefaults = DashStorage.defaults) {
        self.defaults = defaults
        myName = defaults.string(forKey: "zoom.myName") ?? NSFullUserName()
        localeIdentifier = defaults.string(forKey: "zoom.locale") ?? Locale.current.identifier
        autoStart = defaults.object(forKey: "zoom.autoRecord") as? Bool ?? true
        openTranscript = defaults.object(forKey: "zoom.openTranscript") as? Bool ?? true
        summarizeOnStop = defaults.object(forKey: "zoom.summarize") as? Bool ?? true
        saveAudio = defaults.object(forKey: "zoom.saveAudio") as? Bool ?? true
        improveAfterMeeting = defaults.object(forKey: "zoom.improve") as? Bool ?? true
        recordVideo = defaults.bool(forKey: "zoom.recordVideo")
        recordingsFolder = defaults.string(forKey: "zoom.recordingsFolder").map { URL(filePath: $0) } ?? Self.defaultRecordingsFolder
        useCalendar = defaults.bool(forKey: "zoom.calendar")
        reminderMinutes = defaults.object(forKey: "zoom.reminderMinutes") as? Int ?? 2
    }

    var models: [any PersistentModel.Type] { [MeetingRecord.self, TranscriptSegment.self, MeetingSpeaker.self, VoiceProfile.self] }
    var widgets: [WidgetType] { [WidgetType(MeetingWidget.self), WidgetType(UpcomingMeetingsWidget.self)] }
    func settingsView() -> AnyView { AnyView(ZoomSettingsView(zoom: self)) }

    func start(host: any ExtensionContext) {
        attach(host)
        monitor?.cancel()
        calendarObserver = calendar.observeChanges { [weak self] in self?.refreshCalendar() }
        monitor = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                self?.poll()
                // The calendar every minute: meetings move, and reminders are due by the minute.
                if ticks % 12 == 0 { self?.refreshCalendar() }
                ticks += 1
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
        if let calendarObserver { NotificationCenter.default.removeObserver(calendarObserver) }
        calendarObserver = nil
        if isRecording { Task { await stopRecording() } }
    }

    /// Asks for calendar access, then turns the calendar on.
    func enableCalendar() async {
        if calendar.access == .notAsked { _ = await calendar.requestAccess() }
        calendarAccess = calendar.access
        useCalendar = calendarAccess == .granted
    }

    func refreshCalendar() {
        calendarAccess = calendar.access
        upcoming = useCalendar ? calendar.upcoming() : []
        remind()
    }

    /// `zoom.meeting_soon` once per meeting, `reminderMinutes` before it starts.
    func remind(now: Date = .now) {
        for meeting in upcoming where meeting.start > now && meeting.start.timeIntervalSince(now) <= Double(reminderMinutes) * 60 {
            guard reminded.insert(meeting.id + meeting.start.formatted(.iso8601)).inserted else { continue }
            host?.emit("zoom.meeting_soon", from: self, title: "\(meeting.title) starts at \(meeting.start.formatted(date: .omitted, time: .shortened))",
                       detail: meeting.joinURL?.absoluteString, importance: .notable)
        }
    }

    /// The calendar meeting happening now (from 10 minutes before it starts), if any.
    func calendarMeeting(at now: Date = .now) -> CalendarMeeting? {
        upcoming.first { $0.isHappening(at: now) }
    }

    private func poll() {
        isZoomRunning = ZoomAccessibility.isZoomRunning
        guard isZoomRunning else {
            inMeeting = false
            // Zoom quit: any recording ends (two checks in a row, so a relaunch of Zoom isn't one).
            if isRecording {
                zoomGoneChecks += 1
                if zoomGoneChecks >= 2 { Task { await stopRecording(reason: "Zoom quit.") } }
            }
            return
        }
        zoomGoneChecks = 0
        // In a meeting: a meeting window (Accessibility), or Zoom using the microphone or speakers
        // (Core Audio), which holds through screen sharing, the mini window and full screen.
        let window = ZoomAccessibility.isTrusted && ZoomAccessibility.isInMeeting
        let pids = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier?.hasPrefix("us.zoom") == true }.map(\.processIdentifier)
        let audio = ZoomAudioActivity.isActive(pids: pids) ?? false
        let inMeeting = window || audio
        observe(inMeeting: inMeeting, participants: window ? ZoomAccessibility.participants() : participants)
        // Zoom's transcript panel has every speaker's name: read it whenever a recording runs, even
        // when the meeting window itself can't be seen (screen sharing, the mini window).
        if isRecording, ZoomAccessibility.isTrusted, let meetingID = currentMeetingID {
            // The meeting window and its controls can take a few seconds to show: try for a minute.
            if transcriptTries > 0 {
                transcriptTries -= 1
                if ZoomAccessibility.isTranscriptOpen || ZoomAccessibility.openTranscript() { transcriptTries = 0 }
            }
            addCaptions(ZoomAccessibility.captionLines(), to: meetingID)
        }
    }

    /// Applies one reading of Zoom's windows: the live participants, the current meeting's
    /// participant list, auto-start, and stopping once the meeting window has gone.
    func observe(inMeeting: Bool, participants names: [String]) {
        self.inMeeting = inMeeting
        if inMeeting {
            missedMeetingChecks = 0
            outOfMeetingChecks = 0
            if names != participants { participants = names }
            if let meeting = currentMeeting {
                let union = MeetingRecord.merged(meeting.participants, names)
                if union != meeting.participants { meeting.participants = union }
            }
            if autoStart, !isRecording, !autoStartHeld { Task { await startRecording(automatically: true) } }
        } else {
            // Out of the meeting for two checks in a row: the next one records by itself again.
            outOfMeetingChecks += 1
            if outOfMeetingChecks >= 2 { autoStartHeld = false }
        }
        if !inMeeting, isRecording, startedAutomatically {
            // No meeting window and no Zoom audio for 2 minutes: the meeting is over.
            missedMeetingChecks += 1
            if missedMeetingChecks >= Self.autoStopChecks { Task { await stopRecording(reason: "No sign of the Zoom meeting for 2 minutes.") } }
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
    private func ensurePermissions(automatically: Bool) async -> Bool {
        guard let host else { return false }
        if !CGPreflightScreenCaptureAccess() {
            guard !automatically || !askedScreenCapture else {
                lastError = "Dash can't capture Zoom's audio: allow Dash in Screen & System Audio Recording, then quit and reopen Dash."
                return false
            }
            askedScreenCapture = true
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

    /// Saves Zoom's window structure (`ZoomAccessibility.structure`) next to the recordings and
    /// returns the file: what's read from Zoom next is built from it. Local only.
    func captureStructure(now: Date = .now) throws -> URL {
        guard ZoomAccessibility.isTrusted else { throw ToolError("Dash needs Accessibility permission to read Zoom's windows.") }
        try FileManager.default.createDirectory(at: recordingsFolder, withIntermediateDirectories: true)
        let stamp = now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let file = recordingsFolder.appending(path: "Zoom structure \(stamp).txt")
        let header = "# Zoom window structure, \(now.formatted()) · in meeting: \(inMeeting) · recording: \(isRecording)\n"
        try (header + ZoomAccessibility.structure()).write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func startRecording(automatically: Bool = false) async {
        guard host != nil, !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard await ensurePermissions(automatically: automatically) else {
            if automatically { autoStartHeld = true }
            return
        }
        guard let meetingID = beginMeeting(automatically: automatically) else { return }
        let recorder = MeetingRecorder(
            onSegment: { [weak self] segment in
                Task { @MainActor in self?.add(segment, to: meetingID) }
            },
            onError: { [weak self] error in
                Task { @MainActor in
                    self?.lastError = error.localizedDescription
                    await self?.stopRecording(reason: "Recording failed: \(error.localizedDescription)")
                }
            })
        self.recorder = recorder
        do {
            try await recorder.start(locale: Locale(identifier: localeIdentifier), myName: myName, recording: recordingOptions)
        } catch {
            lastError = error.localizedDescription
            await stopRecording(reason: "Recording couldn't start: \(error.localizedDescription)")
        }
    }

    /// Opens the record of a new meeting with the live participants and marks recording on.
    /// `startRecording` then attaches the audio capture.
    @discardableResult
    func beginMeeting(automatically: Bool = false) -> UUID? {
        guard let host, !isRecording else { return nil }
        isRecording = true
        startedAutomatically = automatically
        missedMeetingChecks = 0
        transcriptTries = openTranscript ? 12 : 0
        lastStopReason = nil
        lastError = nil
        // Named after the calendar event when one is on now; Dashii's summary names it otherwise.
        let event = calendarMeeting()
        let meeting = MeetingRecord(title: event?.title ?? "Zoom meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))")
        if event != nil { namedFromCalendar.insert(meeting.id) }
        meeting.participants = participants
        host.context.insert(meeting)
        try? host.context.save()
        currentMeetingID = meeting.id
        seenCaptions = []
        host.emit("meeting.started", from: self, title: saveAudio ? "Recording a Zoom meeting" : "Transcribing a Zoom meeting", detail: participants.joined(separator: ", "), importance: .notable)
        return meeting.id
    }

    func stopRecording(reason: String = "Stopped.") async {
        guard isRecording else { return }
        isRecording = false
        lastStopReason = reason
        transcriptTries = 0
        if inMeeting { autoStartHeld = true }
        DashLog.info("Zoom recording stopped: \(reason)", category: "zoom")
        let file = await recorder?.stop()
        recorder = nil
        guard let meeting = currentMeeting else { return }
        currentMeetingID = nil
        meeting.endedAt = .now
        let temporary = file?.deletingLastPathComponent().standardizedFileURL == Self.temporaryRecordings.standardizedFileURL
        meeting.recordingPath = temporary ? nil : file?.path
        host?.emit("meeting.ended", from: self, title: "Meeting ended: \(meeting.title)",
                   detail: "\(reason) \(meeting.participants.count) participants" + (meeting.recordingPath.map { ", saved to \(URL(filePath: $0).lastPathComponent)" } ?? ""),
                   importance: .notable)
        try? host?.context.save()
        if let file, improveAfterMeeting {
            do { try await improveTranscript(meeting, audio: file, automatically: true) } catch {
                lastError = "The final transcript failed: \(error.localizedDescription)"
                DashLog.error("Final transcript failed: \(error.localizedDescription)", category: "zoom")
            }
        }
        if temporary, let file { try? FileManager.default.removeItem(at: file) }
        if segments(meeting.id).isEmpty, meeting.recordingPath == nil {
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

    /// The transcript to read: the final one when the recording was transcribed again; otherwise
    /// the user's own lines plus Zoom's captions, when captions were on (they replace the
    /// anonymous "Others" audio); otherwise every live line.
    func namedSegments(_ meetingID: UUID) -> [TranscriptSegment] {
        Self.readable(segments(meetingID))
    }

    static func readable(_ all: [TranscriptSegment]) -> [TranscriptSegment] {
        if all.contains(where: { $0.source == "final" }) { return all.filter { $0.source == "final" } }
        let live = all.filter { $0.source != "live" }
        guard live.contains(where: { $0.source == "captions" }) else { return live }
        return live.filter { $0.source == "captions" || $0.speaker != MeetingRecorder.othersSpeaker }
    }

    /// Who spoke, in order of first words, with how much they said (from the final transcript,
    /// else named captions and your microphone).
    func speakers(_ meetingID: UUID) -> [(name: String, first: Date, last: Date, lines: Int, words: Int)] {
        var result: [String: (first: Date, last: Date, lines: Int, words: Int)] = [:]
        var order: [String] = []
        let all = segments(meetingID)
        let final = all.contains { $0.source == "final" }
        for segment in all where final ? segment.source == "final" && segment.speaker != MeetingRecorder.othersSpeaker
            : segment.source == "captions" || (segment.source == "audio" && segment.speaker == myName) {
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

    /// "[03:15] Ada: …" per line; `numbered` adds "[n] " (Dashii refers to lines by it). A name
    /// Dashii guessed (an inferred line, or a voice in `guessed`) is marked "(guessed)".
    static func transcriptText(_ segments: [TranscriptSegment], since start: Date, numbered: Bool = false, guessed: Set<String> = []) -> String {
        segments.enumerated().map { index, segment in
            let offset = Int(segment.createdAt.timeIntervalSince(start))
            let isGuess = segment.source == "inferred" || (segment.source == "final" && guessed.contains(segment.speakerLabel))
            let speaker = isGuess ? "\(segment.speaker) (guessed)" : segment.speaker
            return (numbered ? "[\(index)] " : "") + String(format: "[%02d:%02d] %@: %@", offset / 60, offset % 60, speaker, segment.text)
        }.joined(separator: "\n")
    }

    func summarize(_ meeting: MeetingRecord) async throws {
        guard let host else { return }
        isSummarizing = true
        defer { isSummarizing = false }
        let lines = namedSegments(meeting.id)
        let final = lines.contains { $0.source == "final" }
        let transcript = Self.transcriptText(lines, since: meeting.startedAt, numbered: true, guessed: guessedLabels(meeting.id))
        let voices = final
            ? "Lines from \"\(myName)\" are the user's microphone; the other voices were told apart in Zoom's audio: \"Speaker 1\", \"Speaker 2\"… are voices not named yet. "
                + "Say which participant a Speaker N most likely is (voices) only when what they say or how others address them makes it clear."
            : "Lines from \"\(myName)\" are the user's microphone; \"\(MeetingRecorder.othersSpeaker)\" is everyone else's audio mixed together. "
                + "Name who said an Others line (speakers) only when the content makes it clear."
        let prompt = """
            Participants seen in Zoom: \(meeting.participants.joined(separator: ", "))
            \(voices) In the report, name people only from what they said.

            <transcript>
            \(transcript)
            </transcript>
            """
        let text = try await host.dashii.complete(
            system: "You summarise work meetings for an engineer: what was discussed, what was decided, and who owes what.",
            prompt: prompt, outputSchema: MeetingReportBuilder.schema, effort: "low")
        let result = try JSONValue.parse(text)
        if !namedFromCalendar.contains(meeting.id) { meeting.title = result["title"]?.string ?? meeting.title }
        meeting.summary = result["summary"]?.string ?? ""
        // The "Others" lines Dashii could attribute: named, marked as a guess.
        for guess in result["speakers"]?.array ?? [] {
            guard let index = guess["line"]?.int, index >= 0, index < lines.count, let name = guess["name"]?.string, !name.isEmpty,
                  lines[index].speaker == MeetingRecorder.othersSpeaker, lines[index].source == "audio" else { continue }
            lines[index].speaker = name
            lines[index].source = "inferred"
        }
        applyVoiceGuesses(result["voices"]?.array ?? [], to: meeting.id)
        meeting.report = MeetingReportBuilder.markdown(result, meeting: meeting)
        meeting.decisions = result["decisions"]?.array?.compactMap(\.string) ?? []
        meeting.actionItems = (try? result["action_items"]?.decode([MeetingRecord.ActionItem].self)) ?? []
        host.emit("meeting.summarized", from: self, title: "Summary ready: \(meeting.title)",
                  detail: "\(meeting.decisions.count) decisions, \(meeting.actionItems.count) action items", importance: .notable)
        try? host.context.save()
    }
}
