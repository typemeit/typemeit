import Foundation

/// Turns each track's words into speaker paragraphs (docs/meetings.md 7.10,
/// 8.3). Pure: no I/O, no singletons.
enum TranscriptMerge {
    /// How far a word's midpoint may sit from the nearest speaker segment
    /// and still be attributed to it, when no segment contains it outright.
    static let nearestSegmentMs = 1000
    /// A turn is cut where another speaker's starts only when both halves
    /// last this long, so two people starting together, or the end of a
    /// sentence the reply starts over, stay whole.
    static let minimumSplitMs = 2000

    /// `segments` is nil in phase 1: every track's words keep that track's
    /// own role as the speaker. Once diarization runs, every track whose
    /// role is not "you" is reassigned per word (8.3). The mic track
    /// ("you") keeps its own role unless `micSegments` split it between the
    /// user and people beside them (`RoomVoices`). Mic-track words whose
    /// midpoint falls inside a dictation span are dropped before paragraphs form.
    static func paragraphs(
        tracks: [TrackWords], segments: [SpeakerSegment]?, micSegments: [SpeakerSegment]? = nil, dictations: [Meeting.Span], gap: Duration
    ) -> [Meeting.Paragraph] {
        var assigned: [(word: Transcriber.Word, speaker: String)] = []
        for track in tracks {
            let isMic = track.role == Meeting.Speaker.you
            let words = isMic ? track.words.filter { word in !dictations.contains { contains($0, midpoint(of: word)) } } : track.words
            if let trackSegments = isMic ? micSegments : segments {
                var previousSpeaker = track.role
                for word in words {
                    let speaker = speaker(for: word, segments: trackSegments, fallback: previousSpeaker)
                    assigned.append((word, speaker))
                    previousSpeaker = speaker
                }
            } else {
                assigned.append(contentsOf: words.map { ($0, track.role) })
            }
        }

        // Each speaker's words become that speaker's turns first, then a turn
        // is cut where someone else's starts inside it, so the transcript reads
        // in time order. Sorting the words of both tracks together would cut
        // two people talking at once into one-word paragraphs; a turn of
        // fillers alone ("um") is dropped rather than allowed to cut one.
        var bySpeaker: [String: [Transcriber.Word]] = [:]
        var order: [String] = []
        for entry in assigned {
            if bySpeaker[entry.speaker] == nil { order.append(entry.speaker) }
            bySpeaker[entry.speaker, default: []].append(entry.word)
        }
        let turns = order.flatMap { speaker in
            self.turns(of: bySpeaker[speaker]!.sorted { $0.start < $1.start }, gap: gap).map { (speaker: speaker, words: $0) }
        }.filter { !$0.words.allSatisfy(isFiller) }
        // A short turn inside another speaker's ("yeah" under a sentence) is
        // an aside: that turn is cut where it starts, however short the
        // halves, so the aside sits where it was said and not after the turn.
        var paragraphs: [Meeting.Paragraph] = []
        for turn in turns {
            let others = turns.indices.filter { turns[$0].speaker != turn.speaker }
            let saidInside = others.contains { isAside(turn.words, within: turns[$0].words) }
            let cuts = others.map { turns[$0].words[0].start }
            let asideCuts = others.filter { isAside(turns[$0].words, within: turn.words) }.map { turns[$0].words[0].start }
            for words in split(turn.words, at: cuts, always: asideCuts) {
                paragraphs.append(Meeting.Paragraph(
                    speaker: turn.speaker, startMs: words[0].start.milliseconds, endMs: words[words.count - 1].end.milliseconds,
                    text: words.map(\.text).joined(separator: " "), aside: saidInside ? true : nil))
            }
        }
        // A pause alone never starts a paragraph: one speaker's paragraphs
        // with nobody else's between them are one. An aside comes before
        // the rest of the turn it was said in when both start together.
        var joined: [Meeting.Paragraph] = []
        for paragraph in paragraphs.sorted(by: { ($0.startMs, $0.aside == true ? 0 : 1) < ($1.startMs, $1.aside == true ? 0 : 1) }) {
            if let last = joined.last, last.speaker == paragraph.speaker {
                joined[joined.count - 1] = Meeting.Paragraph(
                    speaker: last.speaker, startMs: last.startMs, endMs: max(last.endMs, paragraph.endMs), text: last.text + " " + paragraph.text,
                    aside: last.aside == true && paragraph.aside == true ? true : nil)
            } else {
                joined.append(paragraph)
            }
        }
        return joined
    }

    /// One speaker's words as turns, split where a word starts more than
    /// `gap` after the previous one ended.
    private static func turns(of words: [Transcriber.Word], gap: Duration) -> [[Transcriber.Word]] {
        var turns: [[Transcriber.Word]] = []
        for word in words {
            if let last = turns.last?.last, word.start - last.end <= gap {
                turns[turns.count - 1].append(word)
            } else {
                turns.append([word])
            }
        }
        return turns
    }

    /// `words` cut before the first word starting at or after each of
    /// `cuts`, where both halves last `minimumSplitMs`, and at each of
    /// `always` whatever the halves last.
    private static func split(_ words: [Transcriber.Word], at cuts: [Duration], always: [Duration]) -> [[Transcriber.Word]] {
        let minimum = Duration.milliseconds(minimumSplitMs)
        let within = { (cut: Duration) in cut > words[0].start && cut < words[words.count - 1].end }
        var pending = cuts.filter(within).sorted()
        var pendingAlways = always.filter(within).sorted()
        var pieces: [[Transcriber.Word]] = [[]]
        for word in words {
            if let first = pieces[pieces.count - 1].first, let last = pieces[pieces.count - 1].last {
                let forced = pendingAlways.first.map { word.start >= $0 } ?? false
                let long = last.end - first.start >= minimum && words[words.count - 1].end - word.start >= minimum
                if forced || (pending.first.map { word.start >= $0 } ?? false) && long { pieces.append([]) }
            }
            pending.removeAll { $0 <= word.start }
            pendingAlways.removeAll { $0 <= word.start }
            pieces[pieces.count - 1].append(word)
        }
        return pieces
    }

    /// `turn` is shorter than `minimumSplitMs`, reads as a sentence of its
    /// own, and `host`, another speaker's turn, has words before it starts,
    /// from then on, and past its end. A sentence starts with a capital and
    /// ends in ".", "?" or "!": a fragment ("the", "and then") is the
    /// diarizer flickering mid-sentence. On a 67-minute room recording that
    /// kept 32 of 104 short turns, the replies ("Yeah.", "Sorry, what?").
    private static func isAside(_ turn: [Transcriber.Word], within host: [Transcriber.Word]) -> Bool {
        let start = turn[0].start
        let end = turn[turn.count - 1].end
        return end - start < .milliseconds(minimumSplitMs)
            && turn[0].text.first?.isUppercase == true && turn[turn.count - 1].text.last.map(".?!".contains) == true
            && host[0].start < start && host[host.count - 1].end > end
            && host.contains { $0.start >= start }
    }

    /// "um", "uh," and the like, by the clean-up's rule.
    private static func isFiller(_ word: Transcriber.Word) -> Bool {
        LocalCleanup.isFillerSound(word.text.filter { $0.isLetter })
    }

    private static func midpoint(of word: Transcriber.Word) -> Int {
        (word.start.milliseconds + word.end.milliseconds) / 2
    }

    private static func contains(_ span: Meeting.Span, _ ms: Int) -> Bool {
        ms >= span.startMs && ms < span.endMs
    }

    /// The speaker whose segments cover most of `word`; failing that, the
    /// nearest segment to its midpoint within `nearestSegmentMs`; failing
    /// that, `fallback` (the previous word's speaker, or the track's own role
    /// for the track's first word). Most coverage beat the segment holding
    /// the midpoint on all 13 recordings checked against AssemblyAI on 21
    /// October (487 words under the wrong speaker against 499, of 53,397).
    private static func speaker(for word: Transcriber.Word, segments: [SpeakerSegment], fallback: String) -> String {
        let start = word.start.milliseconds
        let end = word.end.milliseconds
        var covered: [String: Int] = [:]
        for segment in segments where segment.startMs < end && segment.endMs > start {
            covered[segment.speaker, default: 0] += min(segment.endMs, end) - max(segment.startMs, start)
        }
        if let most = covered.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }) {
            return most.key
        }
        let mid = midpoint(of: word)
        if let nearest = segments.min(by: { edgeDistance(mid, $0) < edgeDistance(mid, $1) }),
           edgeDistance(mid, nearest) <= nearestSegmentMs {
            return nearest.speaker
        }
        return fallback
    }

    private static func edgeDistance(_ ms: Int, _ segment: SpeakerSegment) -> Int {
        if ms < segment.startMs { return segment.startMs - ms }
        if ms >= segment.endMs { return ms - segment.endMs }
        return 0
    }
}
