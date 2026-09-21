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

    @Test func aRunOnTheQuieterMicIsDroppedFromTheMic() {
        let mic = words(["hey", "guys", "are", "you", "ready"], startMs: 1000, offsetMs: 50)
        let others = words(["hey", "guys", "are", "you", "ready"], startMs: 1000)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: envelope(0.01), othersEnvelope: envelope(0.1), envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: [], others: others, droppedFromMic: 5, droppedFromOthers: 0))
    }

    @Test func aRunOnTheQuieterFarEndIsDroppedFromTheFarEnd() {
        let mic = words(["hey", "guys"], startMs: 1000)
        let others = words(["Hey", "guys."], startMs: 1000, offsetMs: 120)
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

    @Test func equalLevelsKeepBoth() {
        let mic = words(["hey", "guys"], startMs: 1000)
        let others = words(["hey", "guys"], startMs: 1000)
        let result = EchoFold.fold(mic: mic, others: others, micEnvelope: envelope(0.05), othersEnvelope: envelope(0.05), envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: mic, others: others, droppedFromMic: 0, droppedFromOthers: 0))
    }

    @Test func emptyTracksFoldToNothing() {
        let result = EchoFold.fold(mic: [], others: [], micEnvelope: [], othersEnvelope: [], envelopeHz: 100)
        #expect(result == EchoFold.Result(mic: [], others: [], droppedFromMic: 0, droppedFromOthers: 0))
    }
}
