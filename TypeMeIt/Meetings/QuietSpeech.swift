import Foundation

/// Whether a chunk has speech in it, and the trimmed, louder copy to retry
/// when the model heard nothing (docs/meetings.md 7.10). Pure.
enum QuietSpeech {
    struct Boosted: Equatable {
        let pcm: [Float]
        /// Where the trimmed copy starts in the original chunk.
        let offsetFrames: Int
    }

    private static var rate: Double { AudioCapture.targetFormat.sampleRate }

    private static func activityThreshold(peak: Float) -> Float {
        min(Fixed.meetingQuietActivityCeiling, max(Fixed.meetingQuietActivityFloor, peak * Fixed.meetingQuietActivityShare))
    }

    static func hasSpeech(_ pcm: [Float]) -> Bool {
        guard !pcm.isEmpty else { return false }
        let peak = AudioCapture.peak(pcm)
        guard peak >= Fixed.meetingQuietPeak else { return false }
        let rms = (pcm.reduce(Float(0)) { $0 + $1 * $1 } / Float(pcm.count)).squareRoot()
        guard rms >= Fixed.meetingQuietRMS else { return false }
        let threshold = activityThreshold(peak: peak)
        let active = pcm.reduce(0) { abs($1) >= threshold ? $0 + 1 : $0 }
        return Double(active) / Double(pcm.count) >= Fixed.meetingQuietActiveShare
            && Double(active) / rate >= Fixed.meetingQuietActiveSeconds
    }

    /// Trimmed to the first and last active sample with a pad either side,
    /// and scaled so the peak reaches the target. Nil when nothing is active.
    static func boosted(_ pcm: [Float]) -> Boosted? {
        let peak = AudioCapture.peak(pcm)
        guard peak > 0 else { return nil }
        let threshold = activityThreshold(peak: peak)
        guard let first = pcm.firstIndex(where: { abs($0) >= threshold }),
              let last = pcm.lastIndex(where: { abs($0) >= threshold }) else { return nil }
        let pad = Int(Fixed.meetingQuietPadSeconds * rate)
        let start = max(0, first - pad)
        let end = min(pcm.count, last + 1 + pad)
        let gain = min(Fixed.meetingQuietGainRange.upperBound, max(Fixed.meetingQuietGainRange.lowerBound, Fixed.meetingQuietTargetPeak / peak))
        return Boosted(pcm: pcm[start..<end].map { $0 * gain }, offsetFrames: start)
    }
}
