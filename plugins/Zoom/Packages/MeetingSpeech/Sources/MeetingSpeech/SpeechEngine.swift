import Foundation

/// One recognised word, with its time in the audio (seconds from the start).
public struct SpokenWord: Hashable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let confidence: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float = 1) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }

    /// Words from a recogniser's subword pieces: a piece starting with a space (or "▁") starts a
    /// word, the others ("ose", ".") continue the one before. Confidence is the lowest piece's.
    public static func words(pieces: [(text: String, start: TimeInterval, end: TimeInterval, confidence: Float)]) -> [SpokenWord] {
        var words: [SpokenWord] = []
        for piece in pieces {
            let startsWord = piece.text.hasPrefix(" ") || piece.text.hasPrefix("▁")
            let text = piece.text.replacingOccurrences(of: "▁", with: " ").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if startsWord || words.isEmpty {
                words.append(SpokenWord(text: text, start: piece.start, end: piece.end, confidence: piece.confidence))
            } else {
                let last = words.removeLast()
                words.append(SpokenWord(text: last.text + text, start: last.start, end: piece.end, confidence: min(last.confidence, piece.confidence)))
            }
        }
        return words
    }
}

/// A stretch of audio one voice speaks, by its label in this recording ("S1", "S2"…).
public struct SpeakerTurn: Hashable, Sendable {
    public let speaker: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Who spoke when in one track, and a voiceprint per voice to recognise it in later meetings.
public struct Diarization: Sendable {
    public let turns: [SpeakerTurn]
    public let voiceprints: [String: [Float]]

    public init(turns: [SpeakerTurn], voiceprints: [String: [Float]]) {
        self.turns = turns
        self.voiceprints = voiceprints
    }
}

/// Speech recognition and voice separation over 16 kHz mono samples.
public protocol SpeechEngine: Sendable {
    /// The models are on this Mac (nothing to download).
    var isReady: Bool { get }
    /// Downloads (once) and loads the models; `progress` gets 0…1 while downloading.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func transcribe(_ samples: [Float]) async throws -> [SpokenWord]
    func diarize(_ samples: [Float]) async throws -> Diarization
}
