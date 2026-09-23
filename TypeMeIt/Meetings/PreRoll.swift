import Foundation

/// A ring that keeps the newest `capacity` samples, overwriting the oldest,
/// and never allocates after `init`. Pure.
struct PreRollRing: Equatable {
    let capacity: Int
    private var buffer: [Float]
    private var head = 0
    private(set) var count = 0
    /// Every sample ever appended, kept or overwritten.
    private(set) var total = 0

    init(capacity: Int) {
        self.capacity = capacity
        buffer = [Float](repeating: 0, count: capacity)
    }

    mutating func append(_ samples: [Float]) {
        total += samples.count
        guard capacity > 0 else { return }
        for sample in samples.suffix(capacity) {
            buffer[head] = sample
            head = (head + 1) % capacity
        }
        count = min(capacity, count + samples.count)
    }

    mutating func appendZeros(_ n: Int) {
        append([Float](repeating: 0, count: min(n, capacity)))
        total += max(0, n - capacity)
    }

    /// What is held, oldest first.
    var contents: [Float] {
        guard count > 0 else { return [] }
        let start = (head - count + capacity) % capacity
        return (0..<count).map { buffer[(start + $0) % capacity] }
    }

    /// Zeroes every sample so nothing of it outlives the candidate.
    mutating func discard() {
        for i in buffer.indices { buffer[i] = 0 }
        head = 0
        count = 0
    }
}

/// The audio of a call before the user said record (docs/meetings.md D20,
/// 7.7): the capture's sink from `candidate` until `record` hands the
/// capture to the recorder, or until it is discarded. Memory only.
final class PreRoll: MeetingCaptureSink, @unchecked Sendable {
    struct Taken: Equatable {
        let mic: [Float]
        /// Nil when the capture has no tap.
        let others: [Float]?
        /// Frames received before the oldest one kept.
        let droppedFrames: Int
    }

    let owner: ProcessOwner.Owner
    private let lock = NSLock()
    private var mic: PreRollRing
    private var others: PreRollRing?

    init(owner: ProcessOwner.Owner, seconds: Int, tap: Bool) {
        self.owner = owner
        let capacity = seconds * Int(AudioCapture.targetFormat.sampleRate)
        mic = PreRollRing(capacity: capacity)
        others = tap ? PreRollRing(capacity: capacity) : nil
    }

    func capture(_ capture: MeetingCapture, mic samples: [Float], others farEnd: [Float]?) {
        lock.lock(); defer { lock.unlock() }
        mic.append(samples)
        if let farEnd { others?.append(farEnd) }
    }

    func captureGap(_ capture: MeetingCapture, frames: Int) {
        lock.lock(); defer { lock.unlock() }
        mic.appendZeros(frames)
        others?.appendZeros(frames)
    }

    func captureFailed(_ capture: MeetingCapture, error: Error) {
        Log.meetings.error("Pre-roll capture failed: \(error.localizedDescription)")
    }

    /// The held audio oldest first, the two tracks the same length, and the
    /// rings freed.
    func take() -> Taken {
        lock.lock(); defer { lock.unlock() }
        let micSamples = mic.contents
        var farEnd = others?.contents
        // Resampling can leave the tracks a few frames apart; the far end
        // is trimmed or padded at its start so both end at the seam.
        if let f = farEnd, f.count != micSamples.count {
            farEnd = f.count > micSamples.count ? Array(f.suffix(micSamples.count)) : [Float](repeating: 0, count: micSamples.count - f.count) + f
        }
        let taken = Taken(mic: micSamples, others: farEnd, droppedFrames: mic.total - micSamples.count)
        mic.discard()
        others?.discard()
        return taken
    }

    func discard() {
        lock.lock(); defer { lock.unlock() }
        mic.discard()
        others?.discard()
    }
}
