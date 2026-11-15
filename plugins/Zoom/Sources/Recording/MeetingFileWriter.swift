import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Writes what the meeting capture hears (and, optionally, sees) to a file: Zoom's audio and your
/// microphone as two AAC tracks that play together, plus Zoom's windows as H.264 video.
/// Audio only gives an .m4a; with video it is a .mov. Every call happens on the capture queue.
final class MeetingFileWriter: @unchecked Sendable {
    struct VideoSize: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    /// Longest side of the recorded video; Zoom's windows stay legible and files stay small.
    static let maxVideoSide = 1920

    let url: URL
    private let writer: AVAssetWriter
    private let others: AVAssetWriterInput
    private let me: AVAssetWriterInput
    private let video: AVAssetWriterInput?
    private var started = false
    private var finished = false

    init(url: URL, video size: VideoSize?) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        writer = try AVAssetWriter(outputURL: url, fileType: size == nil ? .m4a : .mov)
        others = Self.audioInput()
        me = Self.audioInput()
        video = size.map(Self.videoInput)
        for input in [others, me] + (video.map { [$0] } ?? []) where writer.canAdd(input) { writer.add(input) }
    }

    /// The file for a meeting: `<folder>/<yyyy-MM-dd HH.mm> Zoom meeting.<m4a|mov>`, numbered when taken.
    static func fileURL(folder: URL, startedAt: Date, video: Bool, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let base = "\(formatter.string(from: startedAt)) Zoom meeting"
        let ext = video ? "mov" : "m4a"
        var url = folder.appending(path: "\(base).\(ext)")
        var number = 2
        while exists(url) {
            url = folder.appending(path: "\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }

    /// The recorded size for a display: aspect kept, longest side at most `maxVideoSide`, even numbers (H.264 needs them).
    static func videoSize(width: Int, height: Int) -> VideoSize {
        let scale = min(1, Double(maxVideoSide) / Double(max(width, height, 1)))
        func even(_ value: Double) -> Int { max(2, Int(value) / 2 * 2) }
        return VideoSize(width: even(Double(width) * scale), height: even(Double(height) * scale))
    }

    private static func audioInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    private static func videoInput(_ size: VideoSize) -> AVAssetWriterInput {
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_500_000, AVVideoExpectedSourceFrameRateKey: 15],
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    func append(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !finished, sampleBuffer.isValid else { return }
        let input: AVAssetWriterInput
        switch type {
        case .audio: input = others
        case .microphone: input = me
        case .screen:
            guard let video, Self.isCompleteFrame(sampleBuffer) else { return }
            input = video
        @unknown default: return
        }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            started = true
        }
        guard writer.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// ScreenCaptureKit also delivers idle and blank frames; only complete ones carry an image.
    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { return false }
        return status == .complete
    }

    /// Closes the file. Returns its URL, or nil when nothing was written (the empty file is removed).
    func finish() async -> URL? {
        guard !finished else { return nil }
        finished = true
        guard started, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        for input in [others, me] + (video.map { [$0] } ?? []) { input.markAsFinished() }
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }
}
