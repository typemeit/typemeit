import Foundation

// Adapted from pasrom/meeting-transcriber, MIT licence
// (https://github.com/pasrom/meeting-transcriber, commit cba4024,
// app/MeetingTranscriber/Sources/EchoBleedDetector.swift).
// Copyright (c) 2025 pasrom
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// Changed for this app (docs/meetings.md 7.10): `analyse` takes the two
// tracks' 10 ms RMS envelopes, already computed by the caller in the same
// read pass that cuts chunks, instead of raw samples — an hour of audio then
// costs 1.4 MB rather than 460 MB resident. The lag search is centred on 0
// rather than on a `micDelay` estimate, since the mic and tap tracks share
// one clock (docs/meetings.md 5.4). The maths that follows the envelope step
// is unchanged.

/// Decides whether a call's two tracks carry the same speech because the
/// loudspeaker output is bleeding back into the microphone.
///
/// **The metric is the share of windows, not a correlation over the file.** A
/// whole-file correlation dilutes partial bleed, and the window *maximum* is
/// not usable either: clean recordings reach a per-window correlation of 0.3
/// to 0.55, so `affectedShareThreshold` sits in the gap between that and the
/// 34 to 77 percent seen in affected recordings.
enum EchoBleedDetector {
    /// Envelope resolution matching `rmsEnvelope`'s default. Correlating
    /// envelopes rather than waveforms is what makes this robust to the two
    /// capture chains having different gain and frequency response, which
    /// they always do.
    static let frameSeconds = 0.010
    static let windowSeconds = 10.0
    static let maxLagSeconds = 0.2
    static let correlationThreshold = 0.7
    static let affectedShareThreshold = 0.15
    /// A share is only evidence once there is something to take a share of;
    /// both floors must be cleared, not either.
    static let minScoredWindows = 3
    static let minAffectedWindows = 2
    /// Below this a track carries no signal, and a dead channel cannot bleed
    /// anywhere.
    static let silenceFloorDBFS = -70.0
    /// A window is scored only when the far end speaks in at least this
    /// share of its frames, a frame counting as speech above
    /// `activeFrameLevel` (-40 dBFS): a window where the far end is quiet
    /// has nothing to bleed, and counting it dilutes the share. Measured on
    /// a 24 September 2026 Slack call on laptop speakers where the far end
    /// spoke a quarter of the time: 14% of all windows, just under the
    /// threshold and marked clean, but 28% of the windows it spoke in.
    static let activeFrameLevel = 0.01
    static let minActiveShare = 0.1

    /// One window's measurement. The lag is what separates real bleed from a
    /// coincidence: bleed peaks at a stable lag near the true echo delay,
    /// whereas two tracks that merely happen to rise and fall together peak
    /// wherever.
    struct WindowScore: Equatable {
        let correlation: Double
        let lagSeconds: Double
    }

    struct Result: Equatable {
        /// Per-window measurements, in order. Never empty: a `Result` is
        /// only produced once a window scored.
        let windowScores: [WindowScore]

        var windowsScored: Int {
            windowScores.count
        }

        /// Derived rather than counted alongside the series, so the summary
        /// and the evidence it summarises cannot disagree.
        var windowsAffected: Int {
            windowScores.count { $0.correlation > EchoBleedDetector.correlationThreshold }
        }

        var affectedWindowShare: Double {
            windowsScored > 0 ? Double(windowsAffected) / Double(windowsScored) : 0
        }

        var isAffected: Bool {
            windowsScored >= EchoBleedDetector.minScoredWindows
                && windowsAffected >= EchoBleedDetector.minAffectedWindows
                && affectedWindowShare > EchoBleedDetector.affectedShareThreshold
        }
    }

    /// The RMS envelope step, factored out so a caller reading a track's
    /// samples once (docs/meetings.md 7.10 step 2) computes both this and
    /// the 100 ms peak envelope for `ChunkCutter` in the same pass.
    static func rmsEnvelope(_ pcm: [Float], sampleRate: Int, hz: Int = 100) -> [Float] {
        let samplesPerFrame = sampleRate / hz
        guard samplesPerFrame > 0 else { return [] }
        let frames = pcm.count / samplesPerFrame
        var out = [Float](repeating: 0, count: frames)
        for f in 0 ..< frames {
            var acc: Float = 0
            for i in (f * samplesPerFrame) ..< ((f + 1) * samplesPerFrame) {
                acc += pcm[i] * pcm[i]
            }
            out[f] = (acc / Float(samplesPerFrame)).squareRoot()
        }
        return out
    }

    /// Returns `nil` when no honest verdict is possible: either track
    /// silent, or less than one full window of overlap. A share computed
    /// over less than one window is not a measurement.
    static func analyse(micEnvelope: [Float], othersEnvelope: [Float], envelopeHz: Int = 100) -> Result? {
        let overlap = min(micEnvelope.count, othersEnvelope.count)
        let frameSeconds = 1.0 / Double(envelopeHz)
        let framesPerWindow = Int(windowSeconds / frameSeconds)
        guard framesPerWindow > 0, overlap >= framesPerWindow else { return nil }

        let mic = micEnvelope[0 ..< overlap].map(Double.init)
        let others = othersEnvelope[0 ..< overlap].map(Double.init)
        guard dbfs(mic) > silenceFloorDBFS, dbfs(others) > silenceFloorDBFS else { return nil }

        let windows = overlap / framesPerWindow
        let maxLag = Int(maxLagSeconds / frameSeconds)
        let scores = (0 ..< windows).compactMap { w -> WindowScore? in
            let range = (w * framesPerWindow) ..< ((w + 1) * framesPerWindow)
            let active = others[range].count { $0 > activeFrameLevel }
            guard Double(active) >= minActiveShare * Double(range.count),
                  let peak = peakCorrelation(mic[range], others[range], maxLag: maxLag, centre: 0) else { return nil }
            return WindowScore(correlation: peak.correlation, lagSeconds: Double(peak.lag) * frameSeconds)
        }
        guard !scores.isEmpty else { return nil }
        return Result(windowScores: scores)
    }

    // MARK: - Pieces

    private static func dbfs(_ envelope: [Double]) -> Double {
        guard !envelope.isEmpty else { return -.infinity }
        let meanSquare = envelope.reduce(0) { $0 + $1 * $1 } / Double(envelope.count)
        let rms = meanSquare.squareRoot()
        return rms > 0 ? 20 * log10(rms) : -.infinity
    }

    /// Highest normalised correlation of `b` against `a` over the lag range,
    /// and the lag it peaked at. `nil` when either side is flat in this
    /// window, which carries no evidence either way.
    private static func peakCorrelation(
        _ a: ArraySlice<Double>,
        _ b: ArraySlice<Double>,
        maxLag: Int,
        centre: Int,
    ) -> (correlation: Double, lag: Int)? {
        var best: (correlation: Double, lag: Int)?
        for offset in -maxLag ... maxLag {
            let lag = centre + offset
            // Shifting `b` right by `lag` and clipping both to the part that
            // still overlaps. Written once rather than as a mirrored pair of
            // branches: a negative lag is the same slice arithmetic with the
            // two offsets swapped.
            let overlap = a.count - abs(lag)
            guard overlap > 1 else { continue }
            let aStart = a.startIndex + max(0, -lag)
            let bStart = b.startIndex + max(0, lag)
            let x = a[aStart ..< (aStart + overlap)]
            let y = b[bStart ..< (bStart + overlap)]
            guard let r = correlation(x, y) else { continue }
            // Floor at -infinity rather than 0: a correlation is signed, and
            // the first candidate has to win however negative it is.
            if r > (best?.correlation ?? -.infinity) {
                best = (correlation: r, lag: lag)
            }
        }
        return best
    }

    /// The two slices are equal-length by construction in `peakCorrelation`.
    private static func correlation(_ x: ArraySlice<Double>, _ y: ArraySlice<Double>) -> Double? {
        let n = x.count
        guard n > 1 else { return nil }
        let mx = x.reduce(0, +) / Double(n)
        let my = y.reduce(0, +) / Double(n)
        var num = 0.0
        var dx = 0.0
        var dy = 0.0
        for (xi, yi) in zip(x, y) {
            let a = xi - mx
            let b = yi - my
            num += a * b
            dx += a * a
            dy += b * b
        }
        guard dx > 0, dy > 0 else { return nil }
        return num / (dx * dy).squareRoot()
    }
}

/// Maps a possibly-absent echo result to the stored `Meeting.Echo` state.
enum EchoVerdict {
    static func verdict(_ result: EchoBleedDetector.Result?) -> Meeting.Echo {
        guard let result else { return .notMeasured }
        return result.isAffected ? .affected : .clean
    }
}
