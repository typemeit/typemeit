import Foundation

/// Nemotron 3 Diarization's output, one probability per speaker slot per
/// 10 ms frame, as turns (docs/meetings.md 8.2). Each frame goes to the
/// likeliest slot above `threshold`, so two people talking at once become
/// one turn at a time, the way pyannote's segments already arrive. Pure.
enum SpeakerFrames {
    /// `probabilities` is frame-major, `speakers` values per frame. A run
    /// shorter than `minimumMs` is dropped, so a flicker between two slots
    /// does not become a turn. Speakers are named by slot, "0" to "7".
    static func segments(probabilities: [Float], speakers: Int, frameMs: Int, threshold: Float, minimumMs: Int) -> [SpeakerSegment] {
        guard speakers > 0 else { return [] }
        let frames = probabilities.count / speakers
        var segments: [SpeakerSegment] = []
        var current: Int?
        var start = 0
        func close(at frame: Int) {
            guard let slot = current, (frame - start) * frameMs >= minimumMs else { return }
            segments.append(SpeakerSegment(speaker: String(slot), startMs: start * frameMs, endMs: frame * frameMs))
        }
        for frame in 0..<frames {
            var best: Int?
            var bestP = threshold
            for slot in 0..<speakers where probabilities[frame * speakers + slot] > bestP {
                best = slot
                bestP = probabilities[frame * speakers + slot]
            }
            guard best != current else { continue }
            close(at: frame)
            current = best
            start = frame
        }
        close(at: frames)
        return segments
    }
}
