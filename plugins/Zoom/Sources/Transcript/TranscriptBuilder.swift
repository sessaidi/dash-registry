import Foundation
import MeetingSpeech

/// Turns the words recognised in a recording into transcript lines: Zoom's track split by voice,
/// your microphone as yours, in time order.
enum TranscriptBuilder {
    struct Line: Equatable, Sendable {
        /// "me" for the microphone, the voice ("S1"…) for Zoom's audio, "" when no voice was found.
        var label: String
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    static let me = "me"
    /// A silence this long starts a new line.
    static let pause: TimeInterval = 1.2
    /// A line this long ends at the next sentence end.
    static let sentenceAfter: TimeInterval = 4
    static let longest: TimeInterval = 25

    /// The final transcript. A line of yours that repeats what Zoom played at the same moment
    /// (your microphone hearing your speakers) is dropped.
    static func transcript(mine: [SpokenWord], others: [SpokenWord], turns: [SpeakerTurn]) -> [Line] {
        let theirs = lines(others.sorted { $0.start < $1.start }) { speaker(at: ($0.start + $0.end) / 2, in: turns) ?? "" }
        let yours = lines(mine.sorted { $0.start < $1.start }) { _ in me }.filter { line in !theirs.contains { isEcho(line, of: $0) } }
        return (yours + theirs).sorted { $0.start < $1.start }
    }

    /// Words grouped into lines: a new line when the voice changes, after a pause, at a sentence
    /// end once the line is long enough, and at `longest` seconds.
    static func lines(_ words: [SpokenWord], label: (SpokenWord) -> String) -> [Line] {
        var lines: [Line] = []
        for word in words {
            let speaker = label(word)
            if var last = lines.last, last.label == speaker, word.start - last.end <= pause, word.end - last.start <= longest,
               !(endsSentence(last.text) && last.end - last.start >= sentenceAfter) {
                last.text += " " + word.text
                last.end = word.end
                lines[lines.count - 1] = last
            } else {
                lines.append(Line(label: speaker, start: word.start, end: word.end, text: word.text))
            }
        }
        return lines
    }

    /// The voice speaking at `time`: the turn holding it, else the nearest one within a second.
    static func speaker(at time: TimeInterval, in turns: [SpeakerTurn]) -> String? {
        if let turn = turns.first(where: { $0.start <= time && time <= $0.end }) { return turn.speaker }
        func distance(_ turn: SpeakerTurn) -> TimeInterval { time < turn.start ? turn.start - time : time - turn.end }
        guard let nearest = turns.min(by: { distance($0) < distance($1) }), distance(nearest) <= 1 else { return nil }
        return nearest.speaker
    }

    /// `line` overlaps `other` in time and most of its words (three or more) are `other`'s.
    static func isEcho(_ line: Line, of other: Line) -> Bool {
        guard line.start < other.end + 1, other.start < line.end + 1 else { return false }
        let mine = words(line.text)
        guard mine.count >= 3 else { return false }
        let theirs = Set(words(other.text))
        return Double(mine.filter(theirs.contains).count) / Double(mine.count) >= 0.6
    }

    /// Voices in the order they first speak.
    static func voices(_ lines: [Line]) -> [String] {
        var order: [String] = []
        for line in lines where line.label != me && !line.label.isEmpty && !order.contains(line.label) { order.append(line.label) }
        return order
    }

    private static func endsSentence(_ text: String) -> Bool { text.last.map { ".?!".contains($0) } ?? false }

    private static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }
}

/// Recognises voices from the ones the user named in earlier meetings.
enum VoiceMatcher {
    /// Voiceprints this close (cosine similarity) are taken as the same person.
    static let threshold: Float = 0.6

    /// Each voice's saved name, when one is close enough; a name goes to one voice at most (the
    /// closest pairs first).
    static func match(_ voiceprints: [String: [Float]], against saved: [(name: String, voiceprint: [Float])]) -> [String: String] {
        var pairs: [(label: String, name: String, score: Float)] = []
        for (label, print) in voiceprints {
            for profile in saved {
                let score = similarity(print, profile.voiceprint)
                if score >= threshold { pairs.append((label, profile.name, score)) }
            }
        }
        var result: [String: String] = [:]
        for pair in pairs.sorted(by: { $0.score > $1.score }) where result[pair.label] == nil && !result.values.contains(pair.name) {
            result[pair.label] = pair.name
        }
        return result
    }

    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for index in a.indices {
            dot += a[index] * b[index]
            normA += a[index] * a[index]
            normB += b[index] * b[index]
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }
}
