import AVFoundation
import Foundation

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: Int64) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendBE(_ value: Float64) {
        Swift.withUnsafeBytes(of: value.bitPattern.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendASCII(_ fourCC: String) {
        append(contentsOf: Array(fourCC.utf8))
    }
}

/// Appends Float32 PCM to a CAF file as Int16, one track of a meeting
/// (docs/meetings.md 7.5). The header is written once, big-endian, with the
/// `data` chunk size set to `-1` — CAF's own "unknown, runs to the end of the
/// file" — so a crash mid-recording still leaves a file `AVAudioFile` opens;
/// nothing after the header is ever patched.
final class TrackWriter: @unchecked Sendable {
    /// Byte sizes of the header's fields, in the order they are written, so
    /// `headerBytes` is their sum rather than a second copy of the count.
    private enum Header {
        static let fileType = 4 // "caff"
        static let version = 2
        static let flags = 2
        static let chunkType = 4 // "desc" or "data"
        static let chunkSize = 8
        static let sampleRate = 8 // Float64
        static let formatID = 4 // "lpcm"
        static let formatFlags = 4
        static let bytesPerPacket = 4
        static let framesPerPacket = 4
        static let channelsPerFrame = 4
        static let bitsPerChannel = 4
        static let editCount = 4

        static let descChunkDataSize = sampleRate + formatID + formatFlags
            + bytesPerPacket + framesPerPacket + channelsPerFrame + bitsPerChannel

        static let totalSize = fileType + version + flags
            + chunkType + chunkSize + descChunkDataSize
            + chunkType + chunkSize + editCount
    }

    static let headerBytes = Header.totalSize

    static func frames(inFileOfSize bytes: Int) -> Int {
        (bytes - headerBytes) / MemoryLayout<Int16>.size
    }

    /// `AVAudioFile`'s PCM converter treats Int16 as Q15 (divides by 2^15 on
    /// the way back to Float), so quantising with the same scale is what
    /// makes `-1...1` round-trip symmetrically; `Int16.max` alone (32767)
    /// would read every sample back about 1 part in 32768 quiet.
    private static let quantiseScale = Float(1 << (Int16.bitWidth - 1))

    private let queue = DispatchQueue(label: "it.typeme.typemeit.meeting-track-writer")
    private let handle: FileHandle
    private let framesPerSecond = Int(AudioCapture.targetFormat.sampleRate)

    private var framesWrittenStorage = 0
    /// One peak per second of audio written, at most `Fixed.meetingSilentSeconds`
    /// long, oldest first.
    private var secondPeaks: [Float] = []
    private var currentSecondPeak: Float = 0
    private var currentSecondFrames = 0
    /// The loudest sample of the whole track.
    private var overallPeak: Float = 0

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        var header = Data(capacity: Header.totalSize)
        header.appendASCII("caff")
        header.appendBE(UInt16(1)) // version
        header.appendBE(UInt16(0)) // flags
        header.appendASCII("desc")
        header.appendBE(Int64(Header.descChunkDataSize))
        header.appendBE(AudioCapture.targetFormat.sampleRate)
        header.appendASCII("lpcm")
        header.appendBE(UInt32(2)) // format flags: little-endian, integer
        header.appendBE(UInt32(MemoryLayout<Int16>.size)) // bytes per packet
        header.appendBE(UInt32(1)) // frames per packet
        header.appendBE(UInt32(1)) // channels
        header.appendBE(UInt32(Int16.bitWidth)) // bits per channel
        header.appendASCII("data")
        header.appendBE(Int64(-1)) // unknown size: runs to end of file
        header.appendBE(UInt32(0)) // edit count
        handle.write(header)
    }

    /// Clamps to ±1, converts to Int16 little-endian, and appends. Runs on
    /// the writer's own queue.
    func append(_ pcm: [Float]) {
        queue.async { [self] in appendOnQueue(pcm) }
    }

    func appendSilence(frames: Int) {
        guard frames > 0 else { return }
        queue.async { [self] in appendOnQueue([Float](repeating: 0, count: frames)) }
    }

    /// Drains the queue and closes the handle. `peak` is the whole track's.
    func finish() -> (frames: Int, peak: Float) {
        queue.sync {
            try? handle.close()
            return (framesWrittenStorage, overallPeak)
        }
    }

    var framesWritten: Int {
        queue.sync { framesWrittenStorage }
    }

    /// Peak over the most recent `Fixed.meetingSilentSeconds` of audio; the
    /// max over what exists before a full window of seconds has been written.
    var recentPeak: Float {
        queue.sync { recentPeakOnQueue() }
    }

    private func appendOnQueue(_ pcm: [Float]) {
        guard !pcm.isEmpty else { return }
        var data = Data(capacity: pcm.count * MemoryLayout<Int16>.size)
        for sample in pcm {
            let clamped = max(-1, min(1, sample))
            let scaled = (clamped * Self.quantiseScale).rounded()
            let quantised = Int16(min(Float(Int16.max), max(Float(Int16.min), scaled)))
            withUnsafeBytes(of: quantised.littleEndian) { data.append(contentsOf: $0) }
            noteSecondPeak(abs(clamped))
        }
        handle.write(data)
        framesWrittenStorage += pcm.count
    }

    private func noteSecondPeak(_ magnitude: Float) {
        currentSecondPeak = max(currentSecondPeak, magnitude)
        overallPeak = max(overallPeak, magnitude)
        currentSecondFrames += 1
        guard currentSecondFrames >= framesPerSecond else { return }
        secondPeaks.append(currentSecondPeak)
        if secondPeaks.count > Fixed.meetingSilentSeconds {
            secondPeaks.removeFirst()
        }
        currentSecondPeak = 0
        currentSecondFrames = 0
    }

    private func recentPeakOnQueue() -> Float {
        let full = secondPeaks.max() ?? 0
        return currentSecondFrames > 0 ? max(full, currentSecondPeak) : full
    }
}
