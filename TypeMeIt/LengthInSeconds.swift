import Foundation

/// "5s", or "1m 05s" past a minute: a dictation's audio, or how long a step
/// of a meeting's processing took.
func lengthInSeconds(ms: Int) -> String {
    let seconds = Int((Double(ms) / 1000).rounded())
    guard seconds >= 60 else { return "\(seconds)s" }
    return String(format: "%dm %02ds", seconds / 60, seconds % 60)
}
