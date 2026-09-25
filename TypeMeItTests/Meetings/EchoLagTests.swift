import Foundation
import Testing
@testable import TypeMeIt

/// A far end that speaks one second in two, its level rising and falling
/// like syllables, and a mic that hears it `lagMs` later at `gain`: an
/// echo's envelopes at 100 Hz.
enum EchoSignal {
    static let hz = 100
    static let quiet: Float = 0.0005

    static func farEnd(seconds: Int) -> [Float] {
        (0 ..< seconds * hz).map { k in
            guard (k / hz) % 2 == 0 else { return quiet }
            return Float(0.02 + 0.08 * abs(sin(Double(k) * 2 * .pi / 37) * sin(Double(k) * 2 * .pi / 11)))
        }
    }

    /// `lagMs` takes the meeting time in ms, so a test can move the lag mid-call.
    static func mic(hearing farEnd: [Float], gain: Float, lagMs: (Int) -> Int) -> [Float] {
        farEnd.indices.map { k in
            let source = k - lagMs(k * 1000 / hz) * hz / 1000
            return quiet + gain * (farEnd.indices.contains(source) ? farEnd[source] : quiet)
        }
    }
}

struct EchoLagTests {
    @Test func readsTheLagAndGainOfAnEcho() throws {
        let farEnd = EchoSignal.farEnd(seconds: 60)
        let lag = EchoLag.read(micEnvelope: EchoSignal.mic(hearing: farEnd, gain: 0.3) { _ in 40 }, othersEnvelope: farEnd, envelopeHz: EchoSignal.hz)
        #expect(!lag.readings.isEmpty)
        #expect(lag.readings.allSatisfy { $0.lagMs == 40 })
        let gain = try #require(lag.gain(at: 30_000))
        #expect(abs(gain - 0.3) < 0.03)
    }

    @Test func followsAJumpInTheLag() {
        // 25 September: the lag held at 25 ms, jumped to 80 ms at a screen share and held.
        let farEnd = EchoSignal.farEnd(seconds: 120)
        let mic = EchoSignal.mic(hearing: farEnd, gain: 0.3) { $0 < 60_000 ? 30 : 80 }
        let lag = EchoLag.read(micEnvelope: mic, othersEnvelope: farEnd, envelopeHz: EchoSignal.hz)
        #expect(lag.lagMs(at: 20_000) == 30)
        #expect(lag.lagMs(at: 100_000) == 80)
    }

    @Test func readsTheMicAheadOfTheFarEnd() {
        // 25 September, 11:25 onwards: the mic 60 ms ahead of the far-end track.
        let farEnd = EchoSignal.farEnd(seconds: 60)
        let lag = EchoLag.read(micEnvelope: EchoSignal.mic(hearing: farEnd, gain: 0.3) { _ in -60 }, othersEnvelope: farEnd, envelopeHz: EchoSignal.hz)
        #expect(lag.lagMs(at: 30_000) == -60)
    }

    @Test func aQuietFarEndGivesNoReading() {
        let quiet = [Float](repeating: EchoSignal.quiet, count: 60 * EchoSignal.hz)
        let lag = EchoLag.read(micEnvelope: EchoSignal.farEnd(seconds: 60), othersEnvelope: quiet, envelopeHz: EchoSignal.hz)
        #expect(lag.readings.isEmpty)
        #expect(lag.lagMs(at: 30_000) == nil)
        #expect(lag.gain(at: 30_000) == nil)
    }

    @Test func aMicThatDoesNotFollowTheFarEndGivesNoReading() {
        let farEnd = EchoSignal.farEnd(seconds: 60)
        // The user alone: speaking while the far end is quiet, quiet while it speaks.
        let mic = farEnd.indices.map { k in (k / EchoSignal.hz) % 2 == 1 ? Float(0.05 + 0.04 * sin(Double(k) * 2 * .pi / 7)) : EchoSignal.quiet }
        let lag = EchoLag.read(micEnvelope: mic, othersEnvelope: farEnd, envelopeHz: EchoSignal.hz)
        #expect(lag.readings.isEmpty)
    }

    @Test func tooShortACallGivesNoReading() {
        let farEnd = EchoSignal.farEnd(seconds: EchoLag.windowSeconds / 2)
        let lag = EchoLag.read(micEnvelope: EchoSignal.mic(hearing: farEnd, gain: 0.3) { _ in 40 }, othersEnvelope: farEnd, envelopeHz: EchoSignal.hz)
        #expect(lag.readings.isEmpty)
    }

    @Test func percentileInterpolatesBetweenValues() {
        #expect(EchoLag.percentile([1, 2, 3, 4, 5], 50) == 3)
        #expect(EchoLag.percentile([1, 2, 3, 4], 50) == 2.5)
        #expect(EchoLag.percentile([7], 30) == 7)
        #expect(EchoLag.median([3, 1, 2]) == 2)
        #expect(EchoLag.median([4, 1, 3, 2]) == 2.5)
    }
}
