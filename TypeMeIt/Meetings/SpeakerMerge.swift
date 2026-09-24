import Foundation

/// Folds a speaker the diarizer found too little of into the speaker whose
/// voice is nearest (docs/meetings.md 8.3). A few seconds of one person
/// split off from the rest is the diarizer's commonest mistake, and a
/// phantom "Speaker 2" costs the reader more than a short line under the
/// wrong name. Pure.
enum SpeakerMerge {
    /// `embeddings` are the diarizer's, one per speaker id. A speaker under
    /// `minimumMs` of talk goes to the nearest by cosine distance among
    /// those at or over it; one without an embedding, or with nobody to go
    /// to, is left alone.
    static func absorbingShort(_ segments: [SpeakerSegment], embeddings: [String: [Float]], minimumMs: Int) -> [SpeakerSegment] {
        var talk: [String: Int] = [:]
        for s in segments { talk[s.speaker, default: 0] += s.endMs - s.startMs }
        let kept = talk.filter { $0.value >= minimumMs }.keys.filter { embeddings[$0] != nil }
        guard !kept.isEmpty else { return segments }
        var into: [String: String] = [:]
        for (speaker, ms) in talk where ms < minimumMs {
            guard let e = embeddings[speaker] else { continue }
            into[speaker] = kept.min { distance(e, embeddings[$0]!) < distance(e, embeddings[$1]!) }
        }
        return segments.map { SpeakerSegment(speaker: into[$0.speaker] ?? $0.speaker, startMs: $0.startMs, endMs: $0.endMs) }
    }

    /// Cosine distance: 0 is the same direction, 2 opposite.
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 2 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return 2 }
        return 1 - dot / (na.squareRoot() * nb.squareRoot())
    }
}
