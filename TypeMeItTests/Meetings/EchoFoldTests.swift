import Foundation
import Testing
@testable import TypeMeIt

struct EchoFoldTests {
    /// Words 500 ms apart, each 300 ms long, starting at `startMs`.
    private func words(_ texts: [String], startMs: Int, offsetMs: Int = 0) -> [Transcriber.Word] {
        texts.enumerated().map { i, text in
            Transcriber.Word(text: text, confidence: 1, start: .milliseconds(startMs + i * 500 + offsetMs), end: .milliseconds(startMs + i * 500 + 300 + offsetMs))
        }
    }

    /// A flat envelope at 100 Hz for 10 s.
    private func envelope(_ level: Float) -> [Float] { [Float](repeating: level, count: 1000) }

    @Test func aRunTheMicHeardJustAfterTheFarEndIsDroppedFromTheMic() {
        let mic = words(["hey", "guys", "are", "you", "ready"], startMs: 1000, offsetMs: 50)
        let others = words(["hey", "guys", "are", "you", "ready"], startMs: 1000)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: envelope(0.01), othersEnvelope: envelope(0.1), envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: [], others: others, droppedFromMic: 5, droppedFromOthers: 0))
    }

    @Test func theEchoGoesEvenWhenItIsTheLouderCopy() {
        // The 25 September call: the far end's own track seven times quieter than its echo.
        let mic = words(["send", "it", "in", "chunks"], startMs: 1000)
        let others = words(["send", "it", "in", "chunks."], startMs: 1000)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: envelope(0.0086), othersEnvelope: envelope(0.0012), envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: [], others: others, droppedFromMic: 4, droppedFromOthers: 0))
    }

    @Test func theUsersVoiceSentBackByTheFarEndIsDroppedFromTheFarEnd() {
        let mic = words(["oh", "yeah"], startMs: 1000)
        let others = words(["Oh", "yeah,"], startMs: 1000, offsetMs: 140)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: envelope(0.1), othersEnvelope: envelope(0.02), envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: mic, others: [], droppedFromMic: 0, droppedFromOthers: 2))
    }

    @Test func aLoneSharedWordIsACoincidence() {
        let mic = words(["yeah"], startMs: 1000)
        let others = words(["yeah"], startMs: 1000, offsetMs: 100)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: envelope(0.01), othersEnvelope: envelope(0.1), envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: mic, others: others, droppedFromMic: 0, droppedFromOthers: 0))
    }

    @Test func aDifferentWordBreaksTheRun() {
        let mic = words(["so", "we", "should", "go"], startMs: 1000)
        let others = words(["so", "no", "should", "go"], startMs: 1000, offsetMs: 100)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: envelope(0.01), othersEnvelope: envelope(0.1), envelopeHz: 100)
        // "so" stands alone; "should go" is a run.
        #expect(result.mic == [mic[0], mic[1]])
        #expect(result.others == others)
        #expect(result.droppedFromMic == 2)
    }

    @Test func wordsOutsideTheToleranceAreNotMatched() {
        let mic = words(["hey", "guys"], startMs: 1000)
        let others = words(["hey", "guys"], startMs: 1000, offsetMs: EchoFold.toleranceMs + 100)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: envelope(0.01), othersEnvelope: envelope(0.1), envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: mic, others: others, droppedFromMic: 0, droppedFromOthers: 0))
    }

    /// The far end's level, a rise and fall every 300 ms, and the mic
    /// hearing it at `gain` 20 ms later: an echo's envelope.
    private func echoing(gain: Float) -> (mic: [Float], others: [Float]) {
        let others = (0..<1000).map { Float(0.02 + 0.02 * sin(Double($0) * 2 * .pi / 30)) }
        let mic = (0..<1000).map { $0 < 2 ? 0 : gain * others[$0 - 2] }
        return (mic, others)
    }

    @Test func aLeftoverWordOfTheFarEndIsEcho() {
        // The tracks heard "going to" and "gonna": no run, but the mic's level follows the far end.
        let mic = [Transcriber.Word(text: "gonna", confidence: 1, start: .milliseconds(5000), end: .milliseconds(5300))]
        let others = [
            Transcriber.Word(text: "going", confidence: 1, start: .milliseconds(4950), end: .milliseconds(5100)),
            Transcriber.Word(text: "to", confidence: 1, start: .milliseconds(5100), end: .milliseconds(5250)),
        ]
        let (micEnvelope, othersEnvelope) = echoing(gain: 0.3)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: micEnvelope, othersEnvelope: othersEnvelope, envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: [], others: others, droppedFromMic: 1, droppedFromOthers: 0))
    }

    @Test func aYeahThatSoundsLikeNothingTheFarEndSaidStays() {
        let mic = [Transcriber.Word(text: "yeah", confidence: 1, start: .milliseconds(5000), end: .milliseconds(5200))]
        let others = [Transcriber.Word(text: "today.", confidence: 1, start: .milliseconds(4700), end: .milliseconds(5100))]
        let (micEnvelope, othersEnvelope) = echoing(gain: 0.3)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: micEnvelope, othersEnvelope: othersEnvelope, envelopeHz: 100)
        #expect(result.mic == mic)
    }

    @Test func aWordWhoseLevelDoesNotFollowTheFarEndStays() {
        let mic = [Transcriber.Word(text: "gonna", confidence: 1, start: .milliseconds(5000), end: .milliseconds(5300))]
        let others = [Transcriber.Word(text: "going", confidence: 1, start: .milliseconds(4950), end: .milliseconds(5100))]
        let (_, othersEnvelope) = echoing(gain: 0.3)
        let micEnvelope = (0..<1000).map { Float(0.05 + 0.04 * sin(Double($0) * 2 * .pi / 7)) }
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: micEnvelope, othersEnvelope: othersEnvelope, envelopeHz: 100)
        #expect(result.mic == mic)
    }

    @Test func anIslandOfMoreThanThreeWordsIsLeftAlone() {
        let mic = words(["gonna", "gonna", "gonna", "gonna"], startMs: 5000)
        let others = words(["going", "going", "going", "going"], startMs: 5000, offsetMs: -50)
        let (micEnvelope, othersEnvelope) = echoing(gain: 0.3)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: micEnvelope, othersEnvelope: othersEnvelope, envelopeHz: 100)
        #expect(result.mic == mic)
    }

    @Test func soundsLikeTakesPrefixesAndCloseSpellings() {
        #expect(EchoFold.soundsLike("gonna", "going"))
        #expect(EchoFold.soundsLike("9", "9am"))
        #expect(EchoFold.soundsLike("niquette", "Nikette"))
        #expect(!EchoFold.soundsLike("how", "Hal"))
        #expect(!EchoFold.soundsLike("yeah", "today."))
    }

    @Test func emptyTracksFoldToNothing() {
        let result = EchoFold.fold(mic: [], others: [], micEnvelope: [], othersEnvelope: [], envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: [], others: [], droppedFromMic: 0, droppedFromOthers: 0))
    }
}
