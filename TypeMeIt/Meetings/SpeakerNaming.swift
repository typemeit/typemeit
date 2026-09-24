import Foundation

/// What the meeting itself showed about who is who (docs/meetings.md D23,
/// 8.6): the roster, the speaking indicator, captions, or a user rename.
/// Read from the meeting window, never from recognising a voice; dies with
/// the meeting.
struct MeetingNames: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case captions, speaking, roster, user
    }

    /// One name's stretch of speaking time, from the speaking indicator.
    struct Span: Codable, Equatable, Sendable {
        var name: String
        var startMs: Int
        var endMs: Int
    }

    /// One caption line: a name and the words it said, at the moment the
    /// line appeared.
    struct Caption: Codable, Equatable, Sendable {
        var name: String
        var startMs: Int
        var text: String
    }

    var source: Source
    var roster: [String]
    var channel: String?
    var spans: [Span]
    var captions: [Caption]?
    /// Which call this was, when the window said: the Meet code
    /// (`abc-defg-hij`) or the huddle's channel. The key a rejoin is
    /// matched on (`MeetingMerge`).
    var call: String? = nil
}

extension MeetingNames {
    /// How many other people a title spells out before `+N`.
    static let titleNames = 2

    /// `#design, Ana, Ben +2`: the channel, then the others' first names,
    /// alphabetical, the user left out. Nil when nobody else was listed.
    func title(excluding userName: String?) -> String? {
        let user = userName?.lowercased()
        let others = roster.filter { $0.lowercased() != user }
        guard !others.isEmpty else { return nil }
        let first = others.map { String($0.split(separator: " ").first ?? Substring($0)) }.sorted()
        var names = first.prefix(MeetingNames.titleNames).joined(separator: ", ")
        if first.count > MeetingNames.titleNames { names += " +\(first.count - MeetingNames.titleNames)" }
        guard let channel, !channel.isEmpty else { return names }
        return "\(channel.hasPrefix("#") ? channel : "#" + channel), \(names)"
    }
}

/// Turns names read off the meeting window into names on speakers and
/// paragraphs (docs/meetings.md 8.6). Pure: no accessibility, no DOM, no
/// I/O — that reading happens elsewhere and hands its result in here.
enum SpeakerNaming {
    /// Steps 1-6 of 8.6. `segments` are the diarizer's speaker segments
    /// (8.3); `names` is what was read off the meeting window for this
    /// meeting. `userName` is the resolved name of the user, if known — the
    /// tile the meeting marks as the user, or `NSFullUserName()`.
    static func align(
        speakers: [Meeting.Speaker],
        segments: [SpeakerSegment],
        paragraphs: [Meeting.Paragraph],
        names: MeetingNames,
        userName: String?,
        lagMs: Int,
        captionMatch: Double,
        minOverlapMs: Int,
        margin: Double
    ) -> (speakers: [Meeting.Speaker], paragraphs: [Meeting.Paragraph]) {
        let spans = names.spans
            .map { MeetingNames.Span(name: $0.name, startMs: $0.startMs - lagMs, endMs: $0.endMs - lagMs) }
            .filter { !isUser($0.name, userName: userName) }
        let captions = (names.captions ?? [])
            .map { MeetingNames.Caption(name: $0.name, startMs: $0.startMs - lagMs, text: $0.text) }
            .filter { !isUser($0.name, userName: userName) }
        let roster = names.roster.filter { !isUser($0, userName: userName) }

        switch names.source {
        case .captions:
            return alignCaptions(speakers: speakers, paragraphs: paragraphs, captions: captions, captionMatch: captionMatch)
        case .speaking:
            let renamed = alignSpeaking(speakers: speakers, segments: segments, spans: spans, minOverlapMs: minOverlapMs, margin: margin)
            return (renamed, paragraphs)
        case .roster:
            return (alignRoster(speakers: speakers, roster: roster), paragraphs)
        case .user:
            return (speakers, paragraphs)
        }
    }

    // MARK: Captions (step 2)

    /// Each far-end paragraph takes the name of the captions that overlap
    /// it in time and share enough of its words; a paragraph no caption
    /// matches keeps its diarized speaker. A reassigned paragraph moves to
    /// a caption-named speaker (`c1`, `c2`… in first-appearance order,
    /// added to `speakers`); a diarized speaker left with no paragraphs is
    /// dropped (`you` is always kept).
    private static func alignCaptions(
        speakers: [Meeting.Speaker],
        paragraphs: [Meeting.Paragraph],
        captions: [MeetingNames.Caption],
        captionMatch: Double
    ) -> (speakers: [Meeting.Speaker], paragraphs: [Meeting.Paragraph]) {
        let speakerById = Dictionary(uniqueKeysWithValues: speakers.map { ($0.id, $0) })
        var nameToId: [String: String] = [:]
        var newSpeakers: [Meeting.Speaker] = []
        var nextId = 1
        var result = paragraphs

        for i in result.indices {
            let paragraph = result[i]
            guard paragraph.speaker != Meeting.Speaker.you else { continue }
            guard speakerById[paragraph.speaker]?.nameSource != .user else { continue }

            let overlapping = captions.filter { $0.startMs >= paragraph.startMs && $0.startMs < paragraph.endMs }
            guard !overlapping.isEmpty else { continue }

            var order: [String] = []
            var textByName: [String: [String]] = [:]
            for caption in overlapping {
                if textByName[caption.name] == nil { order.append(caption.name) }
                textByName[caption.name, default: []].append(caption.text)
            }

            let paragraphTokens = tokens(of: paragraph.text)
            var bestName: String?
            var bestScore = -1.0
            for name in order {
                let score = tokenContainment(captionTokens: tokens(of: textByName[name]!.joined(separator: " ")), paragraphTokens: paragraphTokens)
                if score > bestScore {
                    bestScore = score
                    bestName = name
                }
            }
            guard let name = bestName, bestScore >= captionMatch else { continue }

            let id = nameToId[name] ?? {
                let id = "c\(nextId)"
                nextId += 1
                nameToId[name] = id
                newSpeakers.append(Meeting.Speaker(id: id, name: name, isYou: false, talkMs: 0, nameSource: .captions))
                return id
            }()
            result[i].speaker = id
        }

        let referenced = Set(result.map(\.speaker))
        let kept = speakers.filter { $0.id == Meeting.Speaker.you || referenced.contains($0.id) }
        return (kept + newSpeakers, result)
    }

    /// Lowercase letter/digit tokens, so caption text and paragraph text
    /// compare on words alone.
    private static func tokens(of text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// The fraction of the paragraph's words also said in the caption:
    /// `|caption tokens ∩ paragraph tokens| / |paragraph tokens|`.
    private static func tokenContainment(captionTokens: Set<String>, paragraphTokens: Set<String>) -> Double {
        guard !paragraphTokens.isEmpty else { return 0 }
        return Double(captionTokens.intersection(paragraphTokens).count) / Double(paragraphTokens.count)
    }

    // MARK: Speaking spans (step 3)

    /// The overlap matrix of each diarized speaker's segments against each
    /// name's spans, assigned one-to-one, largest overlap first. A pair is
    /// accepted only when the overlap clears `minOverlapMs` and is at least
    /// `margin` times that speaker's next-best name overlap (computed once,
    /// over every name, not just what remains unassigned).
    private static func alignSpeaking(
        speakers: [Meeting.Speaker],
        segments: [SpeakerSegment],
        spans: [MeetingNames.Span],
        minOverlapMs: Int,
        margin: Double
    ) -> [Meeting.Speaker] {
        let names = orderedUnique(spans.map(\.name))
        let candidates = speakers.filter { !$0.isYou && $0.nameSource != .user }
        guard !names.isEmpty, !candidates.isEmpty else { return speakers }

        var overlapMs: [String: [String: Int]] = [:]
        for speaker in candidates {
            let speakerSegments = segments.filter { $0.speaker == speaker.id }
            var row: [String: Int] = [:]
            for name in names {
                row[name] = overlap(segments: speakerSegments, spans: spans.filter { $0.name == name })
            }
            overlapMs[speaker.id] = row
        }

        var nextBest: [String: Int] = [:]
        for speaker in candidates {
            let sorted = names.map { overlapMs[speaker.id]![$0]! }.sorted(by: >)
            nextBest[speaker.id] = sorted.count >= 2 ? sorted[1] : 0
        }

        var triples: [(speaker: String, name: String, overlap: Int)] = []
        for speaker in candidates {
            for name in names {
                triples.append((speaker.id, name, overlapMs[speaker.id]![name]!))
            }
        }
        triples.sort { $0.overlap > $1.overlap }

        var assignedSpeakers: Set<String> = []
        var assignedNames: Set<String> = []
        var chosen: [String: String] = [:]
        for triple in triples {
            guard !assignedSpeakers.contains(triple.speaker), !assignedNames.contains(triple.name) else { continue }
            guard triple.overlap >= minOverlapMs else { continue }
            guard Double(triple.overlap) >= margin * Double(nextBest[triple.speaker]!) else { continue }
            assignedSpeakers.insert(triple.speaker)
            assignedNames.insert(triple.name)
            chosen[triple.speaker] = triple.name
        }

        return speakers.map { speaker in
            guard let name = chosen[speaker.id] else { return speaker }
            var updated = speaker
            updated.name = name
            updated.nameSource = .speaking
            return updated
        }
    }

    private static func overlap(segments: [SpeakerSegment], spans: [MeetingNames.Span]) -> Int {
        var total = 0
        for segment in segments {
            for span in spans {
                let start = max(segment.startMs, span.startMs)
                let end = min(segment.endMs, span.endMs)
                if end > start { total += end - start }
            }
        }
        return total
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            result.append(value)
        }
        return result
    }

    // MARK: Roster only (step 4)

    /// Nothing is assigned from a roster alone, except the 1:1 case: exactly
    /// one other name and exactly one far-end speaker not already renamed
    /// by the user, where that speaker takes the name.
    private static func alignRoster(speakers: [Meeting.Speaker], roster: [String]) -> [Meeting.Speaker] {
        let candidates = speakers.filter { !$0.isYou && $0.nameSource != .user }
        guard roster.count == 1, candidates.count == 1, let target = candidates.first else { return speakers }
        return speakers.map { speaker in
            guard speaker.id == target.id else { return speaker }
            var updated = speaker
            updated.name = roster[0]
            updated.nameSource = .roster
            return updated
        }
    }

    // MARK: The user's own name (step 5)

    private static func isUser(_ name: String, userName: String?) -> Bool {
        guard let userName, !userName.isEmpty else { return false }
        return name.caseInsensitiveCompare(userName) == .orderedSame
    }
}
