@preconcurrency import FluidAudio
import Foundation

/// `SpeechEngine` on FluidAudio: Parakeet Ultra (25 European languages, found per stretch of
/// audio, so French and English can mix) and pyannote's offline diarization with 256-value
/// WeSpeaker voiceprints. Models download once from Hugging Face into
/// ~/Library/Application Support/FluidAudio/Models; inference runs on the Neural Engine.
public actor FluidSpeechEngine: SpeechEngine {
    static let version: AsrModelVersion = .ultra

    private var asr: AsrManager?
    private var diarizer: OfflineDiarizerManager?

    public init() {}

    public nonisolated var isReady: Bool {
        let diarization = OfflineDiarizerModels.defaultModelsDirectory().appending(path: "speaker-diarization")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: diarization.path)) ?? []
        return AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: Self.version), version: Self.version)
            && files.contains { $0.hasSuffix(".mlmodelc") }
    }

    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        if asr == nil {
            let models = try await AsrModels.downloadAndLoad(version: Self.version) { progress($0.fractionCompleted * 0.95) }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            asr = manager
        }
        if diarizer == nil {
            let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
            try await manager.prepareModels()
            diarizer = manager
        }
        progress(1)
    }

    public func transcribe(_ samples: [Float]) async throws -> [SpokenWord] {
        guard let asr else { throw SpeechEngineError.notPrepared }
        // Under a second of audio has nothing to say (and is below the model's minimum).
        guard samples.count >= 16_000 else { return [] }
        var state = TdtDecoderState.make()
        let result = try await asr.transcribe(samples, decoderState: &state)
        return SpokenWord.words(pieces: (result.tokenTimings ?? []).map { ($0.token, $0.startTime, $0.endTime, $0.confidence) })
    }

    public func diarize(_ samples: [Float]) async throws -> Diarization {
        guard let diarizer else { throw SpeechEngineError.notPrepared }
        guard samples.count >= 16_000 * 5 else { return Diarization(turns: [], voiceprints: [:]) }
        let result = try await diarizer.process(audio: samples)
        let turns = result.segments.map { SpeakerTurn(speaker: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds)) }
        var voiceprints = result.speakerDatabase ?? [:]
        // Without a database, the voice's longest segment stands for it.
        for segment in result.segments.sorted(by: { $0.durationSeconds > $1.durationSeconds }) where voiceprints[segment.speakerId] == nil && !segment.embedding.isEmpty {
            voiceprints[segment.speakerId] = segment.embedding
        }
        return Diarization(turns: turns.sorted { $0.start < $1.start }, voiceprints: voiceprints)
    }
}

public enum SpeechEngineError: LocalizedError {
    case notPrepared

    public var errorDescription: String? { "The speech models aren't loaded." }
}
