@testable import TypeMeIt

extension Transcriber.Word {
    /// A word heard with full confidence from `startMs` to `endMs`.
    static func at(_ text: String, _ startMs: Int, _ endMs: Int) -> Transcriber.Word {
        Transcriber.Word(text: text, confidence: 1, start: .milliseconds(startMs), end: .milliseconds(endMs))
    }
}

/// Back-to-back half-second words from `startMs` to `endMs`.
func words(_ startMs: Int, _ endMs: Int) -> [Transcriber.Word] {
    stride(from: startMs, to: endMs, by: 500).map { .at("word", $0, $0 + 500) }
}

func segment(_ speaker: String, _ start: Int, _ end: Int) -> SpeakerSegment {
    SpeakerSegment(speaker: speaker, startMs: start, endMs: end)
}
