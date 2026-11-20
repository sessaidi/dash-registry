@preconcurrency import AVFoundation
import Foundation

/// Reads a meeting recording for the speech models.
public enum MeetingAudio {
    public static let sampleRate = 16_000

    /// Every audio track of the file as mono 16 kHz samples, in track order.
    public static func tracks(of url: URL) async throws -> [[Float]] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var result: [[Float]] = []
        for track in tracks {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            ])
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            var samples: [Float] = []
            while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
                var length = 0
                var pointer: UnsafeMutablePointer<CChar>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                      let pointer else { continue }
                pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { samples.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 4)) }
            }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            result.append(samples)
        }
        return result
    }
}
