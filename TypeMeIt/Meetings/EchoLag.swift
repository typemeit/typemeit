import Accelerate
import Foundation

/// How long after the far-end track the mic hears the far end, and how loud,
/// read from the two tracks' envelopes every `stepSeconds` (docs/meetings.md
/// D14). The gap is not fixed: on six calls from 21 to 25 September it held
/// for minutes, then jumped by 45 to 90 ms and held again, and after one
/// jump the mic heard the far end 60 ms before the far-end track had it. A
/// window is read only while the far end speaks, and only when the mic
/// follows it closely enough to be its echo. Pure.
struct EchoLag: Equatable {
    struct Reading: Equatable {
        /// Meeting time at the middle of the window.
        let ms: Int
        /// Positive when the mic hears the far end after the far-end track has it.
        let lagMs: Int
        /// The mic's level over the far end's while the far end is loud: how
        /// loud its echo is. Nil when too little of the window was loud.
        let gain: Double?
    }

    let readings: [Reading]

    static let windowSeconds = 20
    static let stepSeconds = 5
    /// The lags searched, mic ahead to mic behind.
    static let earliestMs = -200
    static let latestMs = 400
    /// A window whose best correlation is below this carries no echo to read.
    static let minimumCorrelation = 0.5
    /// A window is read only when the far end speaks in this share of it,
    /// a frame counting as speech `speakingOverQuiet` natural-log units
    /// (7.4 times) above the far end's `quietPercentile` level.
    static let speakingShare = 0.2
    static let speakingOverQuiet = 2.0
    static let quietPercentile = 30.0
    /// The gain is read over the frames where the far end is above this
    /// percentile of its level, and only from a window with more of them than `minimumLoudFrames`.
    static let loudPercentile = 70.0
    static let minimumLoudFrames = 50
    /// Readings either side of one that its lag is the median of, so a
    /// stray window does not move it.
    static let lagSmoothing = 1
    /// The nearest readings a moment's gain is the median of.
    static let gainReadings = 5
    /// Added before the log, so a silent frame has one.
    private static let logFloor = 1e-4

    /// `micEnvelope` and `othersEnvelope` are RMS at `envelopeHz`, over meeting time.
    static func read(micEnvelope: [Float], othersEnvelope: [Float], envelopeHz: Int) -> EchoLag {
        let count = min(micEnvelope.count, othersEnvelope.count)
        let window = windowSeconds * envelopeHz
        let step = stepSeconds * envelopeHz
        let earliest = earliestMs * envelopeHz / 1000
        let latest = latestMs * envelopeHz / 1000
        guard window > 1, count >= window + latest - earliest else { return EchoLag(readings: []) }
        let micLog = micEnvelope.prefix(count).map { log(Double($0) + logFloor) }
        let othersLog = othersEnvelope.prefix(count).map { log(Double($0) + logFloor) }
        let speaking = percentile(othersLog, quietPercentile) + speakingOverQuiet
        let loud = Float(percentile(othersEnvelope.prefix(count).map(Double.init), loudPercentile))
        // Running sums, so each lag's window of the mic has its mean and spread in constant time.
        var sums = [0.0], squares = [0.0]
        for value in micLog {
            sums.append(sums[sums.count - 1] + value)
            squares.append(squares[squares.count - 1] + value * value)
        }
        var readings: [Reading] = []
        var start = -earliest
        while start + window + latest <= count {
            defer { start += step }
            let farEnd = othersLog[start ..< start + window]
            guard Double(farEnd.filter { $0 > speaking }.count) >= speakingShare * Double(window) else { continue }
            let mean = farEnd.reduce(0, +) / Double(window)
            let spread = (farEnd.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(window)).squareRoot()
            guard spread > 0 else { continue }
            let normalised = farEnd.map { ($0 - mean) / spread }
            var best: (correlation: Double, lag: Int)?
            for lag in earliest ... latest {
                let from = start + lag
                let micMean = (sums[from + window] - sums[from]) / Double(window)
                let micSpread = ((squares[from + window] - squares[from]) / Double(window) - micMean * micMean).squareRoot()
                guard micSpread > 0 else { continue }
                var dot = 0.0
                normalised.withUnsafeBufferPointer { a in
                    micLog.withUnsafeBufferPointer { b in
                        vDSP_dotprD(a.baseAddress!, 1, b.baseAddress! + from, 1, &dot, vDSP_Length(window))
                    }
                }
                let correlation = dot / Double(window) / micSpread
                if correlation > (best?.correlation ?? -.infinity) { best = (correlation, lag) }
            }
            guard let best, best.correlation >= minimumCorrelation else { continue }
            var ratios: [Double] = []
            for k in start ..< start + window where othersEnvelope[k] > loud {
                ratios.append(Double(micEnvelope[k + best.lag]) / Double(othersEnvelope[k]))
            }
            readings.append(Reading(
                ms: (start + window / 2) * 1000 / envelopeHz, lagMs: best.lag * 1000 / envelopeHz,
                gain: ratios.count > minimumLoudFrames ? median(ratios) : nil))
        }
        return EchoLag(readings: readings)
    }

    /// The lag at `ms`: the nearest reading's, smoothed. Nil when nothing was read.
    func lagMs(at ms: Int) -> Int? {
        guard let i = nearest(to: ms) else { return nil }
        let around = readings[max(0, i - EchoLag.lagSmoothing) ... min(readings.count - 1, i + EchoLag.lagSmoothing)]
        return Int(EchoLag.median(around.map { Double($0.lagMs) }).rounded())
    }

    /// The echo's gain at `ms`, from the readings nearest it.
    func gain(at ms: Int) -> Double? {
        let gains = readings.indices.sorted { abs(readings[$0].ms - ms) < abs(readings[$1].ms - ms) }
            .compactMap { readings[$0].gain }.prefix(EchoLag.gainReadings)
        return gains.isEmpty ? nil : EchoLag.median(Array(gains))
    }

    private func nearest(to ms: Int) -> Int? {
        readings.indices.min { abs(readings[$0].ms - ms) < abs(readings[$1].ms - ms) }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The `p`th percentile, interpolating between the two nearest values.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = p / 100 * Double(sorted.count - 1)
        let low = Int(position)
        let high = min(low + 1, sorted.count - 1)
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }
}
