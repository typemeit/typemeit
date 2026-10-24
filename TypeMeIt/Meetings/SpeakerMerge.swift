import Foundation

/// Folds a speaker the diarizer found too little of into the speaker whose
/// voice is nearest (docs/meetings.md 8.3). A few seconds of one person
/// split off from the rest is the diarizer's commonest mistake, and a
/// phantom "Speaker 2" costs the reader more than a short line under the
/// wrong name. Pure.
enum SpeakerMerge {
    /// `embeddings` are the diarizer's, one per speaker id. A speaker under
    /// `minimumMs` of talk goes to the nearest by cosine distance among
    /// those at or over it. One without an embedding, too short for the
    /// embedding model to hear, goes to the speaker whose turns it sits
    /// next to most. With nobody at or over `minimumMs`, nobody moves.
    static func absorbingShort(_ segments: [SpeakerSegment], embeddings: [String: [Float]], minimumMs: Int) -> [SpeakerSegment] {
        let talk = talkMs(segments)
        let kept = Set(talk.filter { $0.value >= minimumMs }.keys)
        guard !kept.isEmpty else { return segments }
        var into: [String: String] = [:]
        for speaker in talk.keys where !kept.contains(speaker) {
            into[speaker] = nearest(to: speaker, among: kept, segments: segments, embeddings: embeddings, talk: talk)
        }
        return relabelled(segments, into)
    }

    /// Folds the speaker with the least talk into the nearest other, again
    /// and again, until at most `maximum` remain: the call's window said
    /// no more voices are there.
    ///
    /// The window counts tiles, not people: two people sharing a laptop
    /// light one tile. So a speaker only folds into one heard through the
    /// same tile (or one of them under no tile), and not when their `voices`
    /// sit `distinct` or further apart. With nobody left who may fold, the
    /// count stays over `maximum`. Pure.
    static func capped(_ segments: [SpeakerSegment], embeddings: [String: [Float]], maximum: Int,
                       tiles: [String: String] = [:], voices: [String: [[Float]]] = [:], distinct: Float = .infinity) -> [SpeakerSegment] {
        var segments = segments
        var tiles = tiles
        var voices = voices
        while true {
            let talk = talkMs(segments)
            guard talk.count > max(maximum, 1) else { return segments }
            let fold = talk.sorted { ($0.value, $0.key) < ($1.value, $1.key) }.lazy.compactMap { quietest -> (String, String)? in
                let others = Set(talk.keys).subtracting([quietest.key]).filter { other in
                    if let a = tiles[quietest.key], let b = tiles[other], a != b { return false }
                    guard let mine = voices[quietest.key], let theirs = voices[other] else { return true }
                    return meanDistance(mine, theirs) < distinct
                }
                guard !others.isEmpty else { return nil }
                return (quietest.key, nearest(to: quietest.key, among: others, segments: segments, embeddings: embeddings, talk: talk))
            }.first
            guard let (from, into) = fold else { return segments }
            segments = relabelled(segments, [from: into])
            tiles[into] = tiles[into] ?? tiles[from]
            voices[into] = (voices[into] ?? []) + (voices[from] ?? [])
        }
    }

    /// The tile each speaker was heard through: the name whose speaking
    /// spans cover more than half of the speaker's time under any span.
    /// A speaker no span covers, or split between tiles, has none.
    static func tiles(of segments: [SpeakerSegment], spans: [MeetingNames.Span]) -> [String: String] {
        var under: [String: [String: Int]] = [:]
        for segment in segments {
            for span in spans {
                let overlap = min(segment.endMs, span.endMs) - max(segment.startMs, span.startMs)
                if overlap > 0 { under[segment.speaker, default: [:]][span.name, default: 0] += overlap }
            }
        }
        return under.compactMapValues { names in
            let total = names.values.reduce(0, +)
            return names.first { $0.value * 2 > total }?.key
        }
    }

    /// The mean cosine distance between every clip of one voice and every
    /// clip of another. One clip of each swings with what was said in it;
    /// on the 12 October call one 30 s clip put two people in one room 0.62
    /// apart and six 20 s clips 0.66.
    static func meanDistance(_ a: [[Float]], _ b: [[Float]]) -> Float {
        let pairs = a.flatMap { x in b.map { distance(x, $0) } }
        return pairs.isEmpty ? 2 : pairs.reduce(0, +) / Float(pairs.count)
    }

    /// The candidate nearest `speaker` by voice when both have embeddings;
    /// otherwise the one whose turns start or end within `borderMs` of
    /// `speaker`'s most often; failing that, the one with the most talk.
    private static func nearest(to speaker: String, among candidates: Set<String>, segments: [SpeakerSegment], embeddings: [String: [Float]], talk: [String: Int]) -> String {
        if let e = embeddings[speaker] {
            let voiced = candidates.filter { embeddings[$0] != nil }
            if let closest = voiced.min(by: { (distance(e, embeddings[$0]!), $0) < (distance(e, embeddings[$1]!), $1) }) { return closest }
        }
        let own = segments.filter { $0.speaker == speaker }
        var borders: [String: Int] = [:]
        for other in segments where candidates.contains(other.speaker) {
            borders[other.speaker, default: 0] += own.filter { $0.startMs - borderMs <= other.endMs && other.startMs <= $0.endMs + borderMs }.count
        }
        return candidates.max { (borders[$0] ?? 0, talk[$0] ?? 0, $1) < (borders[$1] ?? 0, talk[$1] ?? 0, $0) }!
    }

    /// Two turns this close count as next to each other.
    private static let borderMs = 1000

    private static func talkMs(_ segments: [SpeakerSegment]) -> [String: Int] {
        var talk: [String: Int] = [:]
        for s in segments { talk[s.speaker, default: 0] += s.endMs - s.startMs }
        return talk
    }

    private static func relabelled(_ segments: [SpeakerSegment], _ into: [String: String]) -> [SpeakerSegment] {
        segments.map { SpeakerSegment(speaker: into[$0.speaker] ?? $0.speaker, startMs: $0.startMs, endMs: $0.endMs) }
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
