@preconcurrency import AVFAudio
import CoreMedia
import DashKit
import Foundation
import ScreenCaptureKit
import Speech

/// Captures Zoom's audio output and your microphone with ScreenCaptureKit and
/// transcribes each on-device with SpeechAnalyzer. Mic audio is attributed to you;
/// Zoom's output is attributed to "Others" (Zoom does not expose who is speaking).
/// With a `Recording`, the same capture is also saved to a file (and Zoom's windows as video).
final class MeetingRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Segment: Sendable {
        let speaker: String
        let text: String
    }

    /// Where and what to save besides the transcript.
    struct Recording: Sendable {
        let folder: URL
        let startedAt: Date
        let video: Bool
    }

    static let zoomBundleID = "us.zoom.xos"
    /// The speaker of everything Zoom plays: every other participant, mixed together.
    static let othersSpeaker = "Others"

    /// Who a capture stream's audio belongs to: the microphone is you, Zoom's output is everyone else.
    static func speaker(for type: SCStreamOutputType, myName: String) -> String {
        type == .microphone ? myName : othersSpeaker
    }

    private let queue = DispatchQueue(label: "dev.sessaidi.Dash.meeting-audio")
    private var stream: SCStream?
    private var others: TranscriptionPipeline?
    private var me: TranscriptionPipeline?
    private var file: MeetingFileWriter?
    private let onSegment: @Sendable (Segment) -> Void
    private let onError: @Sendable (Error) -> Void

    init(onSegment: @escaping @Sendable (Segment) -> Void, onError: @escaping @Sendable (Error) -> Void) {
        self.onSegment = onSegment
        self.onError = onError
    }

    func start(locale: Locale, myName: String, recording: Recording? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let zoom = content.applications.first(where: { $0.bundleIdentifier == Self.zoomBundleID }) else {
            throw ToolError("Zoom is not running.")
        }
        guard let display = Self.display(showing: zoom, in: content) else { throw ToolError("No display available for capture.") }

        others = try await TranscriptionPipeline.make(locale: locale, speaker: Self.speaker(for: .audio, myName: myName), onSegment: onSegment)
        me = try await TranscriptionPipeline.make(locale: locale, speaker: Self.speaker(for: .microphone, myName: myName), onSegment: onSegment)

        let filter = SCContentFilter(display: display, including: [zoom], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        var videoSize: MeetingFileWriter.VideoSize?
        if recording?.video == true {
            // Zoom's windows on that display (everything else is left out), at up to 15 frames a second.
            let scale = Double(filter.pointPixelScale)
            videoSize = MeetingFileWriter.videoSize(width: Int(filter.contentRect.width * scale), height: Int(filter.contentRect.height * scale))
            configuration.width = videoSize!.width
            configuration.height = videoSize!.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 15)
            configuration.queueDepth = 6
        } else {
            // Audio only: keep the mandatory video stream tiny and slow.
            configuration.width = 2
            configuration.height = 2
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        }
        if let recording {
            let url = MeetingFileWriter.fileURL(folder: recording.folder, startedAt: recording.startedAt, video: recording.video)
            file = try MeetingFileWriter(url: url, video: videoSize)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        if videoSize != nil { try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) }
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capturing and transcribing. Returns the saved recording, if one was written.
    @discardableResult
    func stop() async -> URL? {
        try? await stream?.stopCapture()
        stream = nil
        // Let samples already queued reach the file before closing it.
        let file = queue.sync { self.file }
        let url = await file?.finish()
        await others?.finish()
        await me?.finish()
        others = nil
        me = nil
        self.file = nil
        return url
    }

    /// The display showing Zoom's largest window (its meeting), else the first one.
    static func display(showing zoom: SCRunningApplication, in content: SCShareableContent) -> SCDisplay? {
        let window = content.windows
            .filter { $0.owningApplication?.bundleIdentifier == zoom.bundleIdentifier && $0.isOnScreen && $0.windowLayer == 0 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let window else { return content.displays.first }
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        return content.displays.first { $0.frame.contains(center) } ?? content.displays.first
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        file?.append(sampleBuffer, of: type)
        switch type {
        case .audio: others?.append(sampleBuffer)
        case .microphone: me?.append(sampleBuffer)
        default: break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError(error)
    }
}

/// One audio source feeding one SpeechAnalyzer.
final class TranscriptionPipeline: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var converter: AVAudioConverter?
    private var results: Task<Void, Never>?

    private init(analyzer: SpeechAnalyzer, format: AVAudioFormat, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.format = format
        self.input = input
    }

    static func make(locale: Locale, speaker: String, onSegment: @escaping @Sendable (MeetingRecorder.Segment) -> Void) async throws -> TranscriptionPipeline {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw ToolError("On-device transcription does not support \(locale.identifier).")
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ToolError("No audio format available for transcription.")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.start(inputSequence: stream)
        let pipeline = TranscriptionPipeline(analyzer: analyzer, format: format, input: continuation)
        pipeline.results = Task {
            do {
                for try await result in transcriber.results {
                    if let segment = segment(speaker: speaker, text: String(result.text.characters)) { onSegment(segment) }
                }
            } catch {}
        }
        return pipeline
    }

    /// A transcript line from one finalized result; nil when it's only whitespace.
    static func segment(speaker: String, text: String) -> MeetingRecorder.Segment? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : MeetingRecorder.Segment(speaker: speaker, text: text)
    }

    /// Called on the capture queue.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid, let description = sampleBuffer.formatDescription else { return }
        let source = AVAudioFormat(cmAudioFormatDescription: description)
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, bufferListNoCopy: list.unsafePointer) else { return }
            if let converted = convert(buffer) { input.yield(AnalyzerInput(buffer: converted)) }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return copy(buffer) }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// The capture buffer is only valid inside `withAudioBufferList`, so same-format audio is copied.
    private func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }

    func finish() async {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await results?.value
    }
}
