import Accelerate
import Foundation

/// Names for numbered speakers from the voices of people named in earlier
/// meetings (docs/meetings.md 8.7). Pure: `VoiceLibrary` keeps the voices.
///
/// Measured on 21 recorded calls on 6 October, each named from the other 20:
/// 76 of 77 voices whose person had been heard before got the right name,
/// through the call audio, the laptop speakers and across a room. With each
/// voice's own person taken out of training, as a stranger, no stranger
/// reached a 0.5 posterior (the highest 90th percentile was 0.30), while 69
/// of the 76 right names did. Narrowing to the call's roster made strangers
/// confident in a colleague's name, so every learned person stays a candidate.
enum VoiceNames {
    /// A stretch of one speaker's talk, cut from the track it was heard on.
    struct Clip: Equatable, Sendable {
        let speaker: String
        let role: Meeting.Track.Role
        let range: Range<Int>
    }

    /// Who a speaker is, for learning: the user, or a name the meeting's
    /// window or the user gave. Nil for one still unknown (`SpeakerAssign`)
    /// and for the room of a recording never diarized.
    static func label(of speaker: Meeting.Speaker) -> String? {
        if speaker.isYou { return youName }
        guard !SpeakerAssign.isUnknown(speaker), speaker.id != Meeting.Speaker.room else { return nil }
        let name = speaker.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// What the user is learned and suggested as, the name the mic track carries.
    static let youName = "You"

    /// A meeting's voices under the speakers they belong to now: a speaker
    /// merged into another (`SpeakerAssign.merge`) lends its clips to the one
    /// holding its paragraphs. Clips of a speaker no longer in the meeting go.
    static func regrouped(_ voices: [String: [[Float]]], in meeting: Meeting) -> [String: [[Float]]] {
        let present = Set(meeting.speakers.map(\.id))
        var out: [String: [[Float]]] = [:]
        for id in voices.keys.sorted() {
            let holder = present.contains(id) ? id : meeting.paragraphs.first { $0.mergedFrom == id }?.speaker
            if let holder { out[holder, default: []] += voices[id]! }
        }
        return out
    }

    // MARK: Clips

    /// Each paragraph cut into clips of at most `longestMs` from the track
    /// its speaker is heard on, leaving out any clip another speaker on that
    /// track covers for more than `crosstalkShare` of it, and any shorter than
    /// `shortestMs`. On a call with echo, the mic also holds the far end
    /// through the laptop speakers: a far-end paragraph with no mic paragraph
    /// within `echoPadMs` is cut from the mic too, as that person's voice.
    static func clips(of meeting: Meeting, longestMs: Int, shortestMs: Int, crosstalkShare: Double, echoPadMs: Int) -> [Clip] {
        let roles = Set(meeting.tracks.map(\.role))
        func role(of speaker: String) -> Meeting.Track.Role? {
            guard meeting.kind == .call else { return roles.contains(.room) ? .room : nil }
            return speaker == Meeting.Speaker.you || RoomVoices.isVoice(speaker) ? .mic : .others
        }
        var spans: [Meeting.Track.Role: [(speaker: String, range: Range<Int>)]] = [:]
        for paragraph in meeting.paragraphs where paragraph.endMs > paragraph.startMs {
            guard let heard = role(of: paragraph.speaker) else { continue }
            spans[heard, default: []].append((paragraph.speaker, paragraph.startMs..<paragraph.endMs))
            // The mic hears everyone on a call; the far-end track only the far end.
            if heard == .others { spans[.mic, default: []].append((paragraph.speaker, paragraph.startMs..<paragraph.endMs)) }
        }
        func covered(_ range: Range<Int>, on track: Meeting.Track.Role, by speaker: String) -> Int {
            (spans[track] ?? []).filter { $0.speaker != speaker }.reduce(0) { $0 + overlap($1.range, range) }
        }
        let micSpans = (spans[.mic] ?? []).filter { role(of: $0.speaker) == .mic }.map(\.range)
        var clips: [Clip] = []
        for paragraph in meeting.paragraphs {
            guard let heard = role(of: paragraph.speaker), roles.contains(heard) else { continue }
            for range in windows(paragraph.startMs..<paragraph.endMs, longestMs: longestMs, shortestMs: shortestMs) {
                if Double(covered(range, on: heard, by: paragraph.speaker)) <= crosstalkShare * Double(range.count) {
                    clips.append(Clip(speaker: paragraph.speaker, role: heard, range: range))
                }
                let padded = (range.lowerBound - echoPadMs)..<(range.upperBound + echoPadMs)
                if heard == .others, meeting.echo == .affected, roles.contains(.mic), !micSpans.contains(where: { overlap($0, padded) > 0 }) {
                    clips.append(Clip(speaker: paragraph.speaker, role: .mic, range: range))
                }
            }
        }
        return clips
    }

    /// A span in pieces of at most `longestMs`; a tail shorter than
    /// `shortestMs` joins the piece before it, past `longestMs` only by that tail.
    static func windows(_ span: Range<Int>, longestMs: Int, shortestMs: Int) -> [Range<Int>] {
        var pieces: [Range<Int>] = []
        var start = span.lowerBound
        while span.upperBound - start >= shortestMs {
            var end = start + longestMs
            if span.upperBound - end < shortestMs { end = span.upperBound }
            end = min(end, span.upperBound)
            pieces.append(start..<end)
            start = end
        }
        return pieces
    }

    private static func overlap(_ a: Range<Int>, _ b: Range<Int>) -> Int {
        max(0, min(a.upperBound, b.upperBound) - max(a.lowerBound, b.lowerBound))
    }

    // MARK: Who is who

    /// Softmax regression over the people heard so far: class-balanced, so
    /// the user's hundreds of clips do not drown a colleague's dozen, with
    /// an L2 penalty of one over the number of clips, trained by full-batch
    /// gradient descent with momentum. On the 6 October calls it named the
    /// same voices as scikit-learn's `LogisticRegression(class_weight:
    /// "balanced")` and matched its posteriors to two places.
    struct Model: Sendable {
        let names: [String]
        let dimensions: Int
        /// `dimensions × names.count`, row-major: one column per person.
        let weights: [Float]
        let bias: [Float]

        /// Nil without at least two people to tell apart. A name differing
        /// only in case is the same person, under its first spelling.
        static func train(_ examples: [(name: String, vector: [Float])], steps: Int, rate: Float, momentum: Float) -> Model? {
            guard let dimensions = examples.first?.vector.count, dimensions > 0 else { return nil }
            var names: [String] = []
            var index: [String: Int] = [:]
            var labels: [Int] = []
            var rows: [Float] = []
            for example in examples where example.vector.count == dimensions {
                let key = example.name.lowercased()
                if index[key] == nil { index[key] = names.count; names.append(example.name) }
                labels.append(index[key]!)
                rows += example.vector
            }
            let n = labels.count, k = names.count, d = dimensions
            guard k >= 2 else { return nil }
            var counts = [Int](repeating: 0, count: k)
            for label in labels { counts[label] += 1 }
            let sampleWeight = labels.map { 1 / Float(k * counts[$0]) }
            let penalty = 1 / Float(n)
            var transposed = [Float](repeating: 0, count: d * n)
            vDSP_mtrans(rows, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))

            var weights = [Float](repeating: 0, count: d * k), bias = [Float](repeating: 0, count: k)
            var weightStep = weights, biasStep = bias
            var logits = [Float](repeating: 0, count: n * k)
            var gradient = [Float](repeating: 0, count: d * k)
            for _ in 0..<steps {
                if Task.isCancelled { return nil }
                vDSP_mmul(rows, 1, weights, 1, &logits, 1, vDSP_Length(n), vDSP_Length(k), vDSP_Length(d))
                var biasGradient = [Float](repeating: 0, count: k)
                for i in 0..<n {
                    var largest = -Float.infinity
                    for j in 0..<k { logits[i * k + j] += bias[j]; largest = max(largest, logits[i * k + j]) }
                    var total: Float = 0
                    for j in 0..<k { let e = expf(logits[i * k + j] - largest); logits[i * k + j] = e; total += e }
                    for j in 0..<k {
                        let g = (logits[i * k + j] / total - (labels[i] == j ? 1 : 0)) * sampleWeight[i]
                        logits[i * k + j] = g
                        biasGradient[j] += g
                    }
                }
                vDSP_mmul(transposed, 1, logits, 1, &gradient, 1, vDSP_Length(d), vDSP_Length(k), vDSP_Length(n))
                for j in 0..<(d * k) {
                    weightStep[j] = momentum * weightStep[j] - rate * (gradient[j] + penalty * weights[j])
                    weights[j] += weightStep[j]
                }
                for j in 0..<k {
                    biasStep[j] = momentum * biasStep[j] - rate * biasGradient[j]
                    bias[j] += biasStep[j]
                }
            }
            return Model(names: names, dimensions: d, weights: weights, bias: bias)
        }

        /// How likely each person is to be the one voice all `vectors` came
        /// from: each clip's log-probabilities averaged, then normalised.
        func posterior(_ vectors: [[Float]]) -> [Float] {
            let k = names.count
            var mean = [Float](repeating: 0, count: k)
            let usable = vectors.filter { $0.count == dimensions }
            guard !usable.isEmpty else { return mean }
            var logits = [Float](repeating: 0, count: k)
            for vector in usable {
                vDSP_mmul(vector, 1, weights, 1, &logits, 1, 1, vDSP_Length(k), vDSP_Length(dimensions))
                for j in 0..<k { logits[j] += bias[j] }
                let largest = logits.max()!
                let logTotal = logf(logits.reduce(0) { $0 + expf($1 - largest) }) + largest
                for j in 0..<k { mean[j] += (logits[j] - logTotal) / Float(usable.count) }
            }
            let largest = mean.max()!
            let exps = mean.map { expf($0 - largest) }
            let total = exps.reduce(0, +)
            return exps.map { $0 / total }
        }
    }

    /// The likeliest person for each speaker in `voices` with at least
    /// `minimumClips` clips, however unsure, with the model's posterior.
    static func likeliest(for voices: [String: [[Float]]], model: Model, minimumClips: Int) -> [String: Meeting.Speaker.VoiceGuess] {
        var guesses: [String: Meeting.Speaker.VoiceGuess] = [:]
        for (speaker, vectors) in voices where vectors.count >= minimumClips {
            let posterior = model.posterior(vectors)
            guard let best = posterior.indices.max(by: { posterior[$0] < posterior[$1] }) else { continue }
            guesses[speaker] = Meeting.Speaker.VoiceGuess(name: model.names[best], posterior: posterior[best])
        }
        return guesses
    }

    /// A name for each speaker in `voices` whose likeliest person reaches
    /// `minimum` and is not already one of the meeting's `taken` names. A
    /// person goes to one speaker at most, the likelier one. Speakers with
    /// fewer than `minimumClips` clips are left alone.
    static func suggestions(for voices: [String: [[Float]]], taken: Set<String>, model: Model, minimum: Float, minimumClips: Int) -> [String: String] {
        let takenKeys = Set(taken.map { $0.lowercased() })
        var candidates: [(speaker: String, name: String, p: Float)] = []
        for (speaker, vectors) in voices where vectors.count >= minimumClips {
            let posterior = model.posterior(vectors)
            guard let best = posterior.indices.max(by: { posterior[$0] < posterior[$1] }), posterior[best] >= minimum,
                  !takenKeys.contains(model.names[best].lowercased()) else { continue }
            candidates.append((speaker, model.names[best], posterior[best]))
        }
        var chosen: [String: String] = [:]
        var used: Set<String> = []
        for candidate in candidates.sorted(by: { $0.p > $1.p }) where !used.contains(candidate.name.lowercased()) {
            chosen[candidate.speaker] = candidate.name
            used.insert(candidate.name.lowercased())
        }
        return chosen
    }
}
