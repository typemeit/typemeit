import Testing
@testable import TypeMeIt

/// Deterministic pseudo-random noise, so a test's inputs never change
/// between runs.
private struct SeededLCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
        return state
    }

    /// A value in `range`, standing in for an RMS envelope frame.
    mutating func nextFloat(in range: ClosedRange<Float>) -> Float {
        let fraction = Float(next() >> 40) / Float(1 << 24)
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }
}

private func noiseEnvelope(seed: UInt64, count: Int) -> [Float] {
    var lcg = SeededLCG(seed: seed)
    return (0 ..< count).map { _ in lcg.nextFloat(in: 0.05 ... 0.4) }
}

struct EchoBleedDetectorTests {
    @Test func twoSilentEnvelopesAreNotMeasured() {
        let silence = [Float](repeating: 0, count: 60 * 100)
        let result = EchoBleedDetector.analyse(micEnvelope: silence, othersEnvelope: silence)
        #expect(result == nil)
        #expect(EchoVerdict.verdict(result) == .notMeasured)
    }

    @Test func micBleedingIntoTheFarEndFiftyMillisecondsLaterIsAffected() {
        let envelopeHz = 100
        let lagFrames = 5 // 50 ms at 100 Hz
        let count = 60 * envelopeHz
        let mic = noiseEnvelope(seed: 1, count: count)

        // The far end carries the mic's own audio, delayed by lagFrames.
        var others = noiseEnvelope(seed: 2, count: lagFrames)
        others.append(contentsOf: mic.dropLast(lagFrames))

        let result = EchoBleedDetector.analyse(micEnvelope: mic, othersEnvelope: others, envelopeHz: envelopeHz)
        #expect(EchoVerdict.verdict(result) == .affected)
    }

    /// The far end speaks in 4 windows of 30, and bleeds in each: 13% of
    /// all windows, all of the ones it spoke in.
    @Test func bleedWhileTheFarEndRarelySpeaksIsAffected() {
        let envelopeHz = 100
        let lagFrames = 4
        let window = Int(EchoBleedDetector.windowSeconds) * envelopeHz
        let windows = 30
        let speaking: Set<Int> = [3, 11, 19, 27]
        let farEnd = noiseEnvelope(seed: 5, count: windows * window)
        var mic = noiseEnvelope(seed: 6, count: windows * window)
        var others = [Float](repeating: 0.001, count: windows * window)
        for w in speaking {
            for i in (w * window) ..< ((w + 1) * window) {
                others[i] = farEnd[i]
                if i - (w * window) >= lagFrames { mic[i] = farEnd[i - lagFrames] }
            }
        }

        let result = EchoBleedDetector.analyse(micEnvelope: mic, othersEnvelope: others, envelopeHz: envelopeHz)
        #expect(result?.windowsScored == speaking.count)
        #expect(EchoVerdict.verdict(result) == .affected)
    }

    @Test func twoIndependentNoiseEnvelopesAreClean() {
        let count = 60 * 100
        let mic = noiseEnvelope(seed: 11, count: count)
        let others = noiseEnvelope(seed: 97, count: count)

        let result = EchoBleedDetector.analyse(micEnvelope: mic, othersEnvelope: others)
        #expect(EchoVerdict.verdict(result) == .clean)
    }

    @Test func rmsEnvelopeOfAConstantSignalIsFlat() {
        let sampleRate = 16_000
        let pcm = [Float](repeating: 0.5, count: sampleRate)
        let envelope = EchoBleedDetector.rmsEnvelope(pcm, sampleRate: sampleRate)

        #expect(envelope.count == 100)
        for value in envelope {
            #expect(abs(value - 0.5) < 1e-4)
        }
    }
}
