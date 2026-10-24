import Foundation

/// The people beside the user on a call: voices on the mic track other than
/// the user's (docs/meetings.md 8.3). A person who joins the call on their
/// own device, muted, and talks into the user's laptop is listed in the
/// roster but never lights a tile; their words arrive on the mic. Pure.
///
/// Measured on the 29 September Meet call (three listed, one remote, one
/// beside the user on speakers): the mic track diarized into three voices,
/// the remote voice's echo with far-end words over 63% of its time and the two local
/// voices 1% and 5%, and the local split agreed with AssemblyAI's on 99% of
/// the words both put under one of the two.
enum RoomVoices {
    /// The mic-track segments relabelled: the user's voice and any echo as
    /// `you`, each other voice as `r1`, `r2`… in first-appearance order.
    struct Split: Equatable, Sendable {
        var segments: [SpeakerSegment]
        var others: [String]
    }

    /// A voice beside the user is `r` and its number.
    private static let idPrefix = "r"

    static func isVoice(_ speaker: String) -> Bool {
        speaker.hasPrefix(idPrefix) && Int(speaker.dropFirst(idPrefix.count)) != nil
    }

    /// Roster names that never lit a tile, the user left out: people who
    /// joined but whose own device carried no speech.
    static func silentNames(_ names: MeetingNames, userName: String?) -> [String] {
        let lit = Set(names.spans.map(\.name))
        return names.roster.filter { !lit.contains($0) && !SpeakerNaming.isUser($0, userName: userName) }
    }

    /// The mic voices the far end spoke over for at least `echoShare` of
    /// their time: the loudspeaker coming back, not someone in the room.
    static func echoVoices(_ segments: [SpeakerSegment], farEnd: [Transcriber.Word], echoShare: Double) -> Set<String> {
        var talkMs: [String: Int] = [:]
        var farEndMs: [String: Int] = [:]
        for segment in segments {
            talkMs[segment.speaker, default: 0] += segment.endMs - segment.startMs
            farEndMs[segment.speaker, default: 0] += farEnd.reduce(0) { total, word in
                total + max(0, min(segment.endMs, word.end.milliseconds) - max(segment.startMs, word.start.milliseconds))
            }
        }
        return Set(talkMs.keys.filter { Double(farEndMs[$0]!) >= echoShare * Double(max(talkMs[$0]!, 1)) })
    }

    /// How loud each voice is on the mic: the 90th percentile of the RMS
    /// envelope over its segments, so pauses inside a segment do not count.
    /// The user sits nearest the laptop, so theirs is the loudest.
    static func loudness(_ segments: [SpeakerSegment], envelope: [Float], envelopeHz: Int) -> [String: Float] {
        var frames: [String: [Float]] = [:]
        for segment in segments {
            let start = min(envelope.count, segment.startMs * envelopeHz / 1000)
            let end = min(envelope.count, segment.endMs * envelopeHz / 1000)
            frames[segment.speaker, default: []].append(contentsOf: envelope[start..<end])
        }
        return frames.compactMapValues { values in
            guard !values.isEmpty else { return nil }
            return values.sorted()[values.count * 9 / 10]
        }
    }

    /// The loudest voice that is not echo is the user; every other one that
    /// is not echo becomes `r1`, `r2`…. Nil when fewer than two voices are
    /// left, so the mic stays `you` as before.
    static func split(_ segments: [SpeakerSegment], echo: Set<String>, loudness: [String: Float]) -> Split? {
        var order: [String] = []
        for segment in segments.sorted(by: { $0.startMs < $1.startMs }) where !echo.contains(segment.speaker) && !order.contains(segment.speaker) {
            order.append(segment.speaker)
        }
        guard order.count >= 2, let user = order.max(by: { (loudness[$0] ?? 0) < (loudness[$1] ?? 0) }) else { return nil }
        let others = order.filter { $0 != user }
        let ids = Dictionary(uniqueKeysWithValues: others.enumerated().map { ($1, "\(idPrefix)\($0 + 1)") })
        return Split(
            segments: segments.map { SpeakerSegment(speaker: ids[$0.speaker] ?? Meeting.Speaker.you, startMs: $0.startMs, endMs: $0.endMs) },
            others: others.map { ids[$0]! })
    }
}
