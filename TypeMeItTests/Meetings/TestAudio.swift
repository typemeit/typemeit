import AVFoundation
import Foundation
import Testing
@testable import TypeMeIt

/// A new empty directory under the system temporary directory.
func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// `seconds` of a quiet sine at the capture sample rate.
func sine(seconds: Int) -> [Float] {
    (0..<(seconds * Int(AudioCapture.targetFormat.sampleRate))).map { Float(sin(Double($0) * 0.05)) * 0.3 }
}

/// Writes `samples` as a finished 16-bit CAF track at `url`, as a recording does.
func writeTrack(_ samples: [Float], to url: URL) throws {
    let writer = try TrackWriter(url: url)
    writer.append(samples)
    _ = writer.finish()
}

/// Every sample of the audio file at `url`, decoded to float PCM.
func readSamples(at url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channel = try #require(buffer.floatChannelData)
    return Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
}

/// A far end that speaks one second in two, its level rising and falling
/// like syllables, and a mic that hears it `lagMs` later at `gain`: an
/// echo's envelopes at 100 Hz.
enum EchoSignal {
    static let hz = 100
    static let quiet: Float = 0.0005

    static func farEnd(seconds: Int) -> [Float] {
        (0 ..< seconds * hz).map { k in
            guard (k / hz) % 2 == 0 else { return quiet }
            return Float(0.02 + 0.08 * abs(sin(Double(k) * 2 * .pi / 37) * sin(Double(k) * 2 * .pi / 11)))
        }
    }

    /// `lagMs` takes the meeting time in ms, so a test can move the lag mid-call.
    static func mic(hearing farEnd: [Float], gain: Float, lagMs: (Int) -> Int) -> [Float] {
        farEnd.indices.map { k in
            let source = k - lagMs(k * 1000 / hz) * hz / 1000
            return quiet + gain * (farEnd.indices.contains(source) ? farEnd[source] : quiet)
        }
    }
}
