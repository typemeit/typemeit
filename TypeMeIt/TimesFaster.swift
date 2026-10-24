import Foundation

/// "14× faster": how many times faster than realtime `tookMs` processed
/// `audioMs` of audio, to two significant figures, so the speed reads as a
/// speed rather than a fraction of the audio's length.
func timesFaster(audioMs: Int, tookMs: Int) -> String {
    guard tookMs > 0 else { return "instant" }
    let speed = Double(audioMs) / Double(tookMs)
    let magnitude = Int(floor(log10(speed)))
    let scale = pow(10, Double(1 - magnitude))
    let rounded = (speed * scale).rounded() / scale
    return "\(rounded.formatted(.number.precision(.fractionLength(max(0, 1 - magnitude)))))× faster"
}
