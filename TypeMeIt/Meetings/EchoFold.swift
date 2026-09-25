import Foundation

/// Folds echo out of a speakers call (docs/meetings.md D14). The mic and
/// the far end share one clock, so a run of the same words at the same
/// instant on both tracks is one utterance heard twice, and the copy that
/// arrived later is the echo: the far end's voice reaches the mic through
/// the speakers just after the far-end track has it, and the user's voice
/// comes back from the far end a round trip after the mic. Loudness cannot
/// decide it: the two capture chains differ in gain, and on the 25
/// September Slack call the echo on the mic was up to seven times louder
/// than the far end's own track. Nothing runs unless the echo detector
/// marked the meeting. Pure.
enum EchoFold {
    /// Two words are the same utterance when their starts fall within this.
    static let toleranceMs = 400
    /// A run this long is an echo; a single shared word is a coincidence.
    static let minimumRun = 2
    /// The far end's voice reached the mic 0 to 60 ms after the far-end
    /// track had it (median 20 ms over 33 runs on the 25 September call);
    /// the user's voice came back 140 ms after the mic had it. A run whose
    /// mic copy leads by more than this is the user's.
    static let returnedVoiceMs = 100

    /// What the runs miss: a word or three of the far end left on the mic,
    /// where the tracks' transcripts differ ("gonna" for "going to") or only
    /// one word coincides. Such an island goes when the mic's level follows
    /// the far end's over it and one of its words sounds like a far-end word
    /// said at the same moment. On the 25 September call, against
    /// AssemblyAI, echo islands correlated 0.83 to 0.99 and the user's own
    /// mostly under 0.4; the sounds-like test keeps a "yeah" said into a
    /// far-end pause, which the level alone did not.
    static let islandGapMs = 700
    static let islandMaxWords = 3
    static let islandCorrelation = 0.8
    /// The mic's lag behind the far end searched, and the level either side
    /// of the island taken in with it.
    static let islandMaxLagMs = 100
    static let islandPadMs = 200
    static let soundsLikeWindowMs = 600
    /// Edits allowed as a share of the longer word: "gonna" sounds like
    /// "going", "how" does not sound like "Hal".
    static let soundsLikeDistance = 0.4

    struct Result: Equatable {
        var mic: [Transcriber.Word]
        var others: [Transcriber.Word]
        var droppedFromMic: Int
        var droppedFromOthers: Int
    }

    /// `micEnvelope` and `othersEnvelope` are RMS at `envelopeHz`, over meeting time.
    static func fold(mic: [Transcriber.Word], others: [Transcriber.Word], micEnvelope: [Float], othersEnvelope: [Float], envelopeHz: Int) -> Result {
        let pairs = matches(mic: mic, others: others)
        var dropMic: Set<Int> = []
        var dropOthers: Set<Int> = []
        for run in runs(of: pairs) {
            let micLeads = run.map { others[$0.others].start.milliseconds - mic[$0.mic].start.milliseconds }.sorted()
            if micLeads[micLeads.count / 2] > returnedVoiceMs {
                for pair in run { dropOthers.insert(pair.others) }
            } else {
                for pair in run { dropMic.insert(pair.mic) }
            }
        }
        let keptOthers = others.enumerated().filter { !dropOthers.contains($0.offset) }.map(\.element)
        for island in islands(mic.indices.filter { !dropMic.contains($0) }, of: mic)
        where isEcho(island.map { mic[$0] }, others: keptOthers, micEnvelope: micEnvelope, othersEnvelope: othersEnvelope, envelopeHz: envelopeHz) {
            dropMic.formUnion(island)
        }
        return Result(
            mic: mic.enumerated().filter { !dropMic.contains($0.offset) }.map(\.element),
            others: keptOthers,
            droppedFromMic: dropMic.count, droppedFromOthers: dropOthers.count)
    }

    /// The kept mic words, by index, in groups no more than `islandGapMs` apart.
    private static func islands(_ indices: [Int], of words: [Transcriber.Word]) -> [[Int]] {
        var islands: [[Int]] = []
        for i in indices {
            if let last = islands.last?.last, words[i].start.milliseconds - words[last].end.milliseconds <= islandGapMs {
                islands[islands.count - 1].append(i)
            } else {
                islands.append([i])
            }
        }
        return islands
    }

    private static func isEcho(_ island: [Transcriber.Word], others: [Transcriber.Word], micEnvelope: [Float], othersEnvelope: [Float], envelopeHz: Int) -> Bool {
        guard let first = island.first, let last = island.last, island.count <= islandMaxWords else { return false }
        let from = max(0, (first.start.milliseconds - islandPadMs) * envelopeHz / 1000)
        let to = min(micEnvelope.count, othersEnvelope.count, (last.end.milliseconds + islandPadMs) * envelopeHz / 1000)
        guard from < to else { return false }
        let lagFrames = islandMaxLagMs * envelopeHz / 1000
        let farEnd = ArraySlice(othersEnvelope[from..<to].map(Double.init))
        let heard = ArraySlice(micEnvelope[from..<to].map(Double.init))
        guard let peak = EchoBleedDetector.peakCorrelation(farEnd, heard, maxLag: lagFrames / 2, centre: lagFrames / 2),
              peak.correlation >= islandCorrelation else { return false }
        return island.contains { word in
            others.contains { abs($0.start.milliseconds - word.start.milliseconds) <= soundsLikeWindowMs && soundsLike($0.text, word.text) }
        }
    }

    /// The same word, one a prefix of the other ("9", "9am"), or within
    /// `soundsLikeDistance` edits.
    static func soundsLike(_ a: String, _ b: String) -> Bool {
        let a = normalised(a), b = normalised(b)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        return Double(ModelText.levenshtein(a, b)) <= soundsLikeDistance * Double(max(a.count, b.count))
    }

    struct Pair: Equatable { let mic: Int; let others: Int }

    /// Mic words paired with a far-end word of the same text within the
    /// tolerance, each far-end word used once, in time order.
    static func matches(mic: [Transcriber.Word], others: [Transcriber.Word]) -> [Pair] {
        var pairs: [Pair] = []
        var used: Set<Int> = []
        var j = 0
        for (i, word) in mic.enumerated() {
            let start = word.start.milliseconds
            while j < others.count, others[j].start.milliseconds < start - toleranceMs { j += 1 }
            var best: (index: Int, distance: Int)?
            var k = j
            while k < others.count, others[k].start.milliseconds <= start + toleranceMs {
                if !used.contains(k), normalised(others[k].text) == normalised(word.text) {
                    let distance = abs(others[k].start.milliseconds - start)
                    if best == nil || distance < best!.distance { best = (k, distance) }
                }
                k += 1
            }
            if let best {
                used.insert(best.index)
                pairs.append(Pair(mic: i, others: best.index))
            }
        }
        return pairs
    }

    /// Consecutive pairs on both tracks, `minimumRun` or longer.
    static func runs(of pairs: [Pair]) -> [[Pair]] {
        var runs: [[Pair]] = []
        var current: [Pair] = []
        for pair in pairs {
            if let last = current.last, pair.mic == last.mic + 1, pair.others == last.others + 1 {
                current.append(pair)
            } else {
                if current.count >= minimumRun { runs.append(current) }
                current = [pair]
            }
        }
        if current.count >= minimumRun { runs.append(current) }
        return runs
    }

    static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
