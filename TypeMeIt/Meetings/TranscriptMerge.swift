import Foundation

/// Turns each track's words into speaker paragraphs (docs/meetings.md 7.10,
/// 8.3). Pure: no I/O, no singletons.
enum TranscriptMerge {
    /// How far a word's midpoint may sit from the nearest speaker segment
    /// and still be attributed to it, when no segment contains it outright.
    static let nearestSegmentMs = 1000

    /// `segments` is nil in phase 1: every track's words keep that track's
    /// own role as the speaker. Once diarization runs, every track whose
    /// role is not "you" is reassigned per word (8.3); the mic track
    /// ("you") always keeps its own role. Mic-track words whose midpoint
    /// falls inside a dictation span are dropped before paragraphs form.
    static func paragraphs(
        tracks: [TrackWords], segments: [SpeakerSegment]?, dictations: [Meeting.Span], gap: Duration
    ) -> [Meeting.Paragraph] {
        var assigned: [(word: Transcriber.Word, speaker: String)] = []
        for track in tracks {
            if let segments, track.role != Meeting.Speaker.you {
                var previousSpeaker = track.role
                for word in track.words {
                    let speaker = speaker(for: word, segments: segments, fallback: previousSpeaker)
                    assigned.append((word, speaker))
                    previousSpeaker = speaker
                }
            } else {
                assigned.append(contentsOf: track.words.map { ($0, track.role) })
            }
        }

        assigned.removeAll { entry in
            entry.speaker == Meeting.Speaker.you && dictations.contains { contains($0, midpoint(of: entry.word)) }
        }

        let sorted = assigned.sorted { $0.word.start < $1.word.start }
        return buildParagraphs(from: sorted, gap: gap)
    }

    private static func buildParagraphs(
        from words: [(word: Transcriber.Word, speaker: String)], gap: Duration
    ) -> [Meeting.Paragraph] {
        var paragraphs: [Meeting.Paragraph] = []
        var current: [Transcriber.Word] = []
        var currentSpeaker = ""

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            paragraphs.append(Meeting.Paragraph(
                speaker: currentSpeaker,
                startMs: first.start.milliseconds,
                endMs: last.end.milliseconds,
                text: current.map(\.text).joined(separator: " ")
            ))
        }

        for entry in words {
            if let last = current.last, entry.speaker == currentSpeaker, entry.word.start - last.end <= gap {
                current.append(entry.word)
            } else {
                flush()
                current = [entry.word]
                currentSpeaker = entry.speaker
            }
        }
        flush()
        return paragraphs
    }

    private static func midpoint(of word: Transcriber.Word) -> Int {
        (word.start.milliseconds + word.end.milliseconds) / 2
    }

    private static func contains(_ span: Meeting.Span, _ ms: Int) -> Bool {
        ms >= span.startMs && ms < span.endMs
    }

    /// The segment containing `word`'s midpoint (nearer centre wins when
    /// segments overlap); failing that, the nearest segment within
    /// `nearestSegmentMs`; failing that, `fallback` (the previous word's
    /// speaker, or the track's own role for the track's first word).
    private static func speaker(for word: Transcriber.Word, segments: [SpeakerSegment], fallback: String) -> String {
        let mid = midpoint(of: word)
        let containing = segments.filter { mid >= $0.startMs && mid < $0.endMs }
        if let nearestCentre = containing.min(by: { centreDistance($0, mid) < centreDistance($1, mid) }) {
            return nearestCentre.speaker
        }
        if let nearest = segments.min(by: { edgeDistance(mid, $0) < edgeDistance(mid, $1) }),
           edgeDistance(mid, nearest) <= nearestSegmentMs {
            return nearest.speaker
        }
        return fallback
    }

    private static func centreDistance(_ segment: SpeakerSegment, _ ms: Int) -> Int {
        abs((segment.startMs + segment.endMs) / 2 - ms)
    }

    private static func edgeDistance(_ ms: Int, _ segment: SpeakerSegment) -> Int {
        if ms < segment.startMs { return segment.startMs - ms }
        if ms >= segment.endMs { return ms - segment.endMs }
        return 0
    }
}
