import Foundation
import Testing
@testable import TypeMeIt

struct QuietSpeechTests {
    private let rate = Int(AudioCapture.targetFormat.sampleRate)

    /// `seconds` of silence with a 440 Hz tone at `amplitude` from `from` to `to` seconds.
    private func signal(seconds: Double, amplitude: Float, from: Double, to: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { i in
            let t = Double(i) / Double(rate)
            return t >= from && t < to ? amplitude * Float(sin(2 * .pi * 440 * t)) : 0
        }
    }

    @Test func silenceHasNoSpeech() {
        #expect(!QuietSpeech.hasSpeech([Float](repeating: 0, count: rate * 10)))
    }

    @Test func quietSpeechIsSpeech() {
        #expect(QuietSpeech.hasSpeech(signal(seconds: 10, amplitude: 0.03, from: 2, to: 5)))
    }

    @Test func aClickIsNotSpeech() {
        var pcm = [Float](repeating: 0, count: rate * 10)
        pcm[rate] = 0.5
        #expect(!QuietSpeech.hasSpeech(pcm))
    }

    @Test func theRetryIsTrimmedWithPaddingAndBoostedToTheTarget() throws {
        let pcm = signal(seconds: 10, amplitude: 0.1, from: 2, to: 5)
        let boosted = try #require(QuietSpeech.boosted(pcm))
        let pad = Int(Fixed.meetingQuietPadSeconds * Double(rate))
        // A sine starts at zero, so the first active sample is a few in.
        let slack = rate / 440
        #expect((2 * rate - pad)...(2 * rate - pad + slack) ~= boosted.offsetFrames)
        #expect(abs(boosted.pcm.count - (3 * rate + 2 * pad)) <= 2 * slack)
        #expect(abs(AudioCapture.peak(boosted.pcm) - Fixed.meetingQuietTargetPeak) < 0.001)
    }

    @Test func theGainIsCapped() throws {
        let pcm = signal(seconds: 4, amplitude: 0.01, from: 1, to: 3)
        let boosted = try #require(QuietSpeech.boosted(pcm))
        #expect(abs(AudioCapture.peak(boosted.pcm) - 0.01 * Fixed.meetingQuietGainRange.upperBound) < 0.001)
    }
}
