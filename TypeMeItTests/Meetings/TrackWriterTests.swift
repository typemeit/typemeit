import AVFoundation
import Testing
@testable import TypeMeIt

/// The header the spec's table (docs/meetings.md 7.5) describes, built here
/// field by field rather than borrowed from `TrackWriter` so the test proves
/// the written bytes, not just that the writer agrees with itself.
private func expectedHeader() -> [UInt8] {
    var bytes: [UInt8] = []
    bytes += Array("caff".utf8)
    withUnsafeBytes(of: UInt16(1).bigEndian) { bytes += $0 } // version
    withUnsafeBytes(of: UInt16(0).bigEndian) { bytes += $0 } // flags
    bytes += Array("desc".utf8)
    withUnsafeBytes(of: Int64(32).bigEndian) { bytes += $0 } // desc chunk size
    withUnsafeBytes(of: AudioCapture.targetFormat.sampleRate.bitPattern.bigEndian) { bytes += $0 }
    bytes += Array("lpcm".utf8)
    withUnsafeBytes(of: UInt32(2).bigEndian) { bytes += $0 } // format flags: little-endian, integer
    withUnsafeBytes(of: UInt32(2).bigEndian) { bytes += $0 } // bytes per packet
    withUnsafeBytes(of: UInt32(1).bigEndian) { bytes += $0 } // frames per packet
    withUnsafeBytes(of: UInt32(1).bigEndian) { bytes += $0 } // channels
    withUnsafeBytes(of: UInt32(16).bigEndian) { bytes += $0 } // bits per channel
    bytes += Array("data".utf8)
    withUnsafeBytes(of: Int64(-1).bigEndian) { bytes += $0 } // data chunk size: unknown
    withUnsafeBytes(of: UInt32(0).bigEndian) { bytes += $0 } // edit count
    return bytes
}

final class TrackWriterTests {
    private let dir = tempDir()
    private var url: URL { dir.appendingPathComponent("track.caf") }

    deinit { try? FileManager.default.removeItem(at: dir) }

    @Test func headerBytesMatchTheSpec() throws {
        _ = try TrackWriter(url: url)

        let written = try Data(contentsOf: url)
        #expect(Array(written) == expectedHeader())
        #expect(TrackWriter.headerBytes == expectedHeader().count)
        #expect(TrackWriter.headerBytes == 68)
    }

    @Test func aTruncatedFileOpensAndReportsItsFrameCount() throws {
        try writeTrack([Float](repeating: 0.5, count: 1_000), to: url)

        let fullSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int
        // Truncate mid-frame, to a size that need not be a multiple of 2:
        // the arbitrary crash point the spec's "-1 data chunk" is for.
        let truncatedSize = TrackWriter.headerBytes + 777
        #expect(truncatedSize < fullSize)

        let data = try Data(contentsOf: url).prefix(truncatedSize)
        let truncatedURL = dir.appendingPathComponent("truncated.caf")
        try data.write(to: truncatedURL)

        let file = try AVAudioFile(forReading: truncatedURL)
        #expect(Int(file.length) == TrackWriter.frames(inFileOfSize: truncatedSize))
    }

    @Test func samplesReadBackMatchTheClampedQuantisedInput() throws {
        let input: [Float] = [0, 0.5, -0.5, 1.5, -1.5, 0.999_97]
        try writeTrack(input, to: url)

        let samples = try readSamples(at: url)
        #expect(samples.count == input.count)
        // Signed 16-bit PCM has no code for +1.0 (only -1.0 has one), so a
        // clamped +1 sample is off by exactly one quantisation step; a hair
        // over 1/32768 covers that alongside float rounding in the check.
        let tolerance: Float = 1.0 / 32_768 * 1.01
        for (readBack, original) in zip(samples, input) {
            let clamped = max(-1, min(1, original))
            #expect(abs(readBack - clamped) <= tolerance)
        }
    }

    @Test func appendSilenceAddsZeros() throws {
        let writer = try TrackWriter(url: url)
        writer.appendSilence(frames: 500)
        let (frames, peak) = writer.finish()

        #expect(frames == 500)
        #expect(peak == 0)
        let samples = try readSamples(at: url)
        #expect(samples == [Float](repeating: 0, count: 500))
    }

    @Test func recentPeakReflectsTheLastWindowNotOlderAudio() throws {
        let writer = try TrackWriter(url: url)
        let framesPerSecond = Int(AudioCapture.targetFormat.sampleRate)

        // Before a full window, recentPeak is the max over what exists.
        writer.append([Float](repeating: 0.9, count: framesPerSecond / 2))
        #expect(writer.recentPeak == 0.9)

        // One loud second, then enough quiet seconds to fill and overflow
        // the meetingSilentSeconds window: the loud second falls out of it.
        writer.append([Float](repeating: 0, count: framesPerSecond / 2)) // completes the first second at 0.9
        for _ in 0 ..< Fixed.meetingSilentSeconds {
            writer.append([Float](repeating: 0.01, count: framesPerSecond))
        }

        #expect(abs(writer.recentPeak - 0.01) < 1e-4)
        _ = writer.finish()
    }
}
