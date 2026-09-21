import Foundation

/// Folds echo out of a speakers call (docs/meetings.md D14). The mic and
/// the far end share one clock, so a run of the same words at the same
/// instant on both tracks is one utterance heard twice: the copy that came
/// through a speaker is the quieter one, and it goes. A lone coincident
/// word is never touched, and nothing runs unless the echo detector
/// marked the meeting. Pure.
enum EchoFold {
    /// Two words are the same utterance when their starts fall within this.
    static let toleranceMs = 400
    /// A run this long is an echo; a single shared word is a coincidence.
    static let minimumRun = 2

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
            let startMs = min(mic[run.first!.mic].start.milliseconds, others[run.first!.others].start.milliseconds)
            let endMs = max(mic[run.last!.mic].end.milliseconds, others[run.last!.others].end.milliseconds)
            let micLevel = mean(micEnvelope, fromMs: startMs, toMs: endMs, hz: envelopeHz)
            let othersLevel = mean(othersEnvelope, fromMs: startMs, toMs: endMs, hz: envelopeHz)
            if micLevel < othersLevel {
                for pair in run { dropMic.insert(pair.mic) }
            } else if othersLevel < micLevel {
                for pair in run { dropOthers.insert(pair.others) }
            }
        }
        return Result(
            mic: mic.enumerated().filter { !dropMic.contains($0.offset) }.map(\.element),
            others: others.enumerated().filter { !dropOthers.contains($0.offset) }.map(\.element),
            droppedFromMic: dropMic.count, droppedFromOthers: dropOthers.count)
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

    private static func mean(_ envelope: [Float], fromMs: Int, toMs: Int, hz: Int) -> Float {
        let from = max(0, fromMs * hz / 1000)
        let to = min(envelope.count, max(from + 1, toMs * hz / 1000))
        guard from < to else { return 0 }
        return envelope[from..<to].reduce(0, +) / Float(to - from)
    }

    static func normalised(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
