import Synchronization

/// A preallocated single-producer single-consumer ring of Float32 frames of
/// one or two channels, interleaved (docs/meetings.md 7.5). The audio IO proc
/// writes on the audio thread with no allocation and no lock; the drain queue
/// reads on its own thread. A call's mic and far end are the two channels of
/// one ring, so a frame that does not fit is dropped from both: with a ring
/// each, the drain emptied the mic's before the far end's, the IO proc filled
/// the mic's again in between while the far end's was still full, and a call
/// on 16 October whose drain was starved of CPU came out with its far end
/// 6.5 s ahead of its mic. `head` and `tail` are the only state shared
/// between the two sides, each an ever-increasing count of frames written or
/// read rather than a wrapped index, so the ring distinguishes empty from
/// full without a spare slot; `% capacity` is only used to place a frame in
/// `storage`.
final class AudioRing: @unchecked Sendable {
    let channels: Int
    private let storage: UnsafeMutableBufferPointer<Float>
    /// In frames.
    private let capacity: Int
    private let head = Atomic<Int>(0) // written by the producer, read by both
    private let tail = Atomic<Int>(0) // written by the consumer, read by both
    private let dropped = Atomic<Int>(0)

    /// `channels` is 1 or 2.
    init(frames: Int, channels: Int) {
        self.channels = channels
        capacity = frames
        storage = .allocate(capacity: frames * channels)
    }

    deinit {
        storage.deallocate()
    }

    /// Appends as many frames as the longer source has: the first channel
    /// from `first`, the second from `second`, a source that is nil or runs
    /// short read as zeros, so the two channels keep step. `second` is
    /// ignored on a one-channel ring. Frames that do not fit are dropped and
    /// added to `overruns`. Producer side: called from the audio IO proc.
    func write(_ first: UnsafePointer<Float>?, count firstCount: Int, _ second: UnsafePointer<Float>? = nil, count secondCount: Int = 0) {
        let frames = channels > 1 ? max(firstCount, secondCount) : firstCount
        let head = head.load(ordering: .relaxed)
        let tail = tail.load(ordering: .acquiring)
        let toWrite = max(0, min(frames, capacity - (head - tail)))
        for f in 0 ..< toWrite {
            let slot = (head + f) % capacity * channels
            storage[slot] = f < firstCount ? first?[f] ?? 0 : 0
            if channels > 1 { storage[slot + 1] = f < secondCount ? second?[f] ?? 0 : 0 }
        }
        if toWrite > 0 {
            self.head.store(head + toWrite, ordering: .releasing)
        }
        let overrun = frames - toWrite
        if overrun > 0 {
            dropped.wrappingAdd(overrun, ordering: .relaxed)
        }
    }

    /// For tests; production callers hold `UnsafePointer`s from the IO proc's buffer list already.
    func write(_ first: [Float], _ second: [Float] = []) {
        first.withUnsafeBufferPointer { a in
            second.withUnsafeBufferPointer { b in
                write(a.baseAddress, count: a.count, b.baseAddress, count: b.count)
            }
        }
    }

    /// Appends every frame available right now, the first channel to `first`
    /// and the second to `second`, and returns how many. `second` is left
    /// alone on a one-channel ring. Consumer side: called from the drain queue.
    func read(into first: inout [Float], _ second: inout [Float]) -> Int {
        let tail = tail.load(ordering: .relaxed)
        let head = head.load(ordering: .acquiring)
        let available = head - tail
        guard available > 0 else { return 0 }
        first.reserveCapacity(first.count + available)
        if channels > 1 { second.reserveCapacity(second.count + available) }
        for f in 0 ..< available {
            let slot = (tail + f) % capacity * channels
            first.append(storage[slot])
            if channels > 1 { second.append(storage[slot + 1]) }
        }
        self.tail.store(tail + available, ordering: .releasing)
        return available
    }

    /// Frames written but not yet read. Informational only: a caller acting
    /// on it races the other side by design, the same as `overruns`.
    var available: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)
    }

    /// Frames dropped by `write` because the ring was full, cumulative. A
    /// drop happens only while the ring is full, so whatever was dropped by
    /// the time a `read` returns comes after every frame it returned.
    var overruns: Int {
        dropped.load(ordering: .relaxed)
    }
}
