import AVFoundation
import CoreMedia
import Foundation
import Testing

@Suite("Meeting recording")
struct RecordingTests {
    @Test func fileNamesAreDatedAndNumbered() {
        let folder = URL(filePath: "/tmp/meetings")
        var components = DateComponents(year: 2026, month: 11, day: 14, hour: 9, minute: 5)
        components.timeZone = .current
        let date = Calendar.current.date(from: components)!
        #expect(MeetingFileWriter.fileURL(folder: folder, startedAt: date, video: false, exists: { _ in false }).lastPathComponent == "2026-11-14 09.05 Zoom meeting.m4a")
        let taken: Set<String> = ["2026-11-14 09.05 Zoom meeting.mov", "2026-11-14 09.05 Zoom meeting 2.mov"]
        #expect(MeetingFileWriter.fileURL(folder: folder, startedAt: date, video: true, exists: { taken.contains($0.lastPathComponent) }).lastPathComponent
            == "2026-11-14 09.05 Zoom meeting 3.mov")
    }

    @Test func videoSizeKeepsAspectAndEvenNumbers() {
        #expect(MeetingFileWriter.videoSize(width: 3456, height: 2234) == .init(width: 1920, height: 1240))
        #expect(MeetingFileWriter.videoSize(width: 1281, height: 721) == .init(width: 1280, height: 720))
    }

    @Test func writesBothAudioTracksToM4A() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "zoom-\(UUID().uuidString)/meeting.m4a")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try MeetingFileWriter(url: url, video: nil)
        for index in 0..<50 {
            let time = CMTime(value: CMTimeValue(index * 4800), timescale: 48_000)
            writer.append(try Self.tone(at: time), of: .audio)
            writer.append(try Self.tone(at: time), of: .microphone)
        }
        #expect(await writer.finish() == url)
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 2)
        #expect(try await asset.load(.duration).seconds > 4)
    }

    @Test func nothingWrittenLeavesNoFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "zoom-\(UUID().uuidString).m4a")
        let writer = try MeetingFileWriter(url: url, video: nil)
        #expect(await writer.finish() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// 100 ms of a 440 Hz tone, mono Float32 at 48 kHz, like ScreenCaptureKit's audio.
    static func tone(at time: CMTime) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for frame in 0..<4800 { buffer.floatChannelData![0][frame] = sin(Float(frame) * 2 * .pi * 440 / 48_000) * 0.2 }
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: format.streamDescription, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description,
                             sampleCount: 4800, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
                             sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.featureUnsupported) }
        let status = CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0,
                                                                     bufferList: buffer.audioBufferList)
        guard status == noErr else { throw CocoaError(.featureUnsupported) }
        return sample
    }
}
