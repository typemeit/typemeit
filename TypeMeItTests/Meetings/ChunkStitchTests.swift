import Testing
@testable import TypeMeIt

struct ChunkStitchTests {
    @Test func aRepeatedWordIsDropped() {
        let tail = [Transcriber.Word(text: "hello", confidence: 1, start: .milliseconds(900), end: .milliseconds(1000))]
        let new = [
            Transcriber.Word(text: "hello", confidence: 1, start: .milliseconds(1000), end: .milliseconds(1100)),
            Transcriber.Word(text: "world", confidence: 1, start: .milliseconds(1200), end: .milliseconds(1300)),
        ]
        let result = ChunkStitch.append(new, after: tail, overlapMs: 300)
        #expect(result == tail + [new[1]])
    }

    @Test func aDifferentWordAtTheSameTimeIsKept() {
        let tail = [Transcriber.Word(text: "hello", confidence: 1, start: .milliseconds(900), end: .milliseconds(1000))]
        let new = [Transcriber.Word(text: "goodbye", confidence: 1, start: .milliseconds(950), end: .milliseconds(1050))]
        let result = ChunkStitch.append(new, after: tail, overlapMs: 300)
        #expect(result == tail + new)
    }

    @Test func anEmptyTailReturnsNew() {
        let new = [Transcriber.Word(text: "hi", confidence: 1, start: .milliseconds(0), end: .milliseconds(100))]
        #expect(ChunkStitch.append(new, after: [], overlapMs: 300) == new)
    }

    @Test func anOverlapWithNoWords() {
        let tail = [Transcriber.Word(text: "hi", confidence: 1, start: .milliseconds(0), end: .milliseconds(100))]
        #expect(ChunkStitch.append([], after: tail, overlapMs: 300) == tail)
    }

    @Test func aWordOutsideTheOverlapIsNeverDroppedEvenIfTheTextRepeats() {
        let tail = [Transcriber.Word(text: "hello", confidence: 1, start: .milliseconds(100), end: .milliseconds(200))]
        let new = [Transcriber.Word(text: "hello", confidence: 1, start: .milliseconds(5000), end: .milliseconds(5100))]
        let result = ChunkStitch.append(new, after: tail, overlapMs: 300)
        #expect(result == tail + new)
    }
}
