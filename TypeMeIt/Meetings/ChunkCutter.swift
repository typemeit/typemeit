import Foundation

/// Splits a track's peak envelope into overlapping chunks for the speech
/// model, seaming each cut at the quietest moment near the target length
/// (docs/meetings.md 7.10). Pure: no I/O, no singletons.
enum ChunkCutter {
    /// `peaks` is one value per `frameMs` of audio (100 ms in practice).
    /// Each returned range is milliseconds of meeting time, at most
    /// `maxChunkMs` long; consecutive ranges overlap by exactly `overlapMs`.
    /// The last range always ends at the track's end.
    static func cuts(peaks: [Float], frameMs: Int, maxChunkMs: Int, overlapMs: Int, searchMs: Int) -> [Range<Int>] {
        guard !peaks.isEmpty else { return [] }
        let trackMs = peaks.count * frameMs
        guard trackMs > maxChunkMs else { return [0..<trackMs] }

        var ranges: [Range<Int>] = []
        var start = 0
        while true {
            let nominalEnd = start + maxChunkMs
            if nominalEnd >= trackMs {
                ranges.append(start..<trackMs)
                break
            }
            let end = seam(peaks: peaks, frameMs: frameMs, nominalEnd: nominalEnd, searchMs: searchMs)
            ranges.append(start..<end)
            start = end - overlapMs
        }
        return ranges
    }

    /// The quietest frame at or before `nominalEnd`, no earlier than
    /// `searchMs` before it. The search never looks past the boundary, so a
    /// chunk never exceeds `maxChunkMs`; ties keep the frame nearer the
    /// boundary, so a stretch with nothing quieter cuts right at the limit.
    private static func seam(peaks: [Float], frameMs: Int, nominalEnd: Int, searchMs: Int) -> Int {
        let highFrame = min(peaks.count - 1, nominalEnd / frameMs)
        let lowFrame = max(0, (nominalEnd - searchMs) / frameMs)
        var bestFrame = highFrame
        var bestValue = peaks[highFrame]
        var frame = highFrame - 1
        while frame >= lowFrame {
            if peaks[frame] < bestValue {
                bestValue = peaks[frame]
                bestFrame = frame
            }
            frame -= 1
        }
        return bestFrame * frameMs
    }
}
