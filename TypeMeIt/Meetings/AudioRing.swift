import Synchronization

/// A preallocated single-producer single-consumer ring of Float32 samples
/// (docs/meetings.md 7.5). The audio IO proc writes on the audio thread with
/// no allocation and no lock; the drain queue reads on its own thread. `head`
/// and `tail` are the only state shared between them, each an ever-increasing
/// count of samples written or read rather than a wrapped index, so the ring
/// distinguishes empty from full without a spare slot; `% capacity` is only
/// used to place a sample in `storage`.
final class AudioRing: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int
    private let head = Atomic<Int>(0) // written by the producer, read by both
    private let tail = Atomic<Int>(0) // written by the consumer, read by both
    private let dropped = Atomic<Int>(0)

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Copies what fits into the free space; anything beyond that is dropped
    /// and added to `overruns`. Producer side: called from the audio IO proc.
    func write(_ samples: UnsafePointer<Float>, count: Int) {
        let head = head.load(ordering: .relaxed)
        let tail = tail.load(ordering: .acquiring)
        let free = capacity - (head - tail)
        let toWrite = max(0, min(count, free))
        for i in 0 ..< toWrite {
            storage[(head + i) % capacity] = samples[i]
        }
        if toWrite > 0 {
            self.head.store(head + toWrite, ordering: .releasing)
        }
        let overrun = count - toWrite
        if overrun > 0 {
            dropped.wrappingAdd(overrun, ordering: .relaxed)
        }
    }

    /// Writes `count` zeros, dropping and counting what does not fit, for a
    /// track that has to keep step with a longer buffer from the other.
    /// Producer side, allocation-free.
    func writeZeros(count: Int) {
        let head = head.load(ordering: .relaxed)
        let tail = tail.load(ordering: .acquiring)
        let free = capacity - (head - tail)
        let toWrite = max(0, min(count, free))
        for i in 0 ..< toWrite {
            storage[(head + i) % capacity] = 0
        }
        if toWrite > 0 {
            self.head.store(head + toWrite, ordering: .releasing)
        }
        let overrun = count - toWrite
        if overrun > 0 {
            dropped.wrappingAdd(overrun, ordering: .relaxed)
        }
    }

    /// Convenience for tests; production callers hold an `UnsafePointer` from
    /// the IO proc's buffer list already.
    func write(_ samples: [Float]) {
        samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
            write(base, count: buffer.count)
        }
    }

    /// Appends every sample available right now to `buffer` and returns how
    /// many. Consumer side: called from the drain queue.
    func read(into buffer: inout [Float]) -> Int {
        let tail = tail.load(ordering: .relaxed)
        let head = head.load(ordering: .acquiring)
        let available = head - tail
        guard available > 0 else { return 0 }
        buffer.reserveCapacity(buffer.count + available)
        for i in 0 ..< available {
            buffer.append(storage[(tail + i) % capacity])
        }
        self.tail.store(tail + available, ordering: .releasing)
        return available
    }

    /// Samples written but not yet read. Informational only: a caller acting
    /// on it races the other side by design, the same as `overruns`.
    var available: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)
    }

    /// Samples dropped by `write` because the ring was full, cumulative.
    var overruns: Int {
        dropped.load(ordering: .relaxed)
    }
}
