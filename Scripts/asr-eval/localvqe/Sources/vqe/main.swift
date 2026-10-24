import AVFoundation
import FluidAudio
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: vqe <mic.wav> <reference.wav> <out.wav>\n".utf8))
    exit(2)
}
let converter = AudioConverter()
let mic = try converter.resampleAudioFile(path: arguments[1])
var reference = try converter.resampleAudioFile(path: arguments[2])
if reference.count < mic.count {
    reference.append(contentsOf: [Float](repeating: 0, count: mic.count - reference.count))
} else {
    reference.removeLast(reference.count - mic.count)
}

let loadStart = Date()
let manager = try await LocalVqeManager(config: LocalVqeConfig(variant: .v13, chunk: .batch256ms, computeUnits: .cpuOnly))
let loadSeconds = Date().timeIntervalSince(loadStart)

let runStart = Date()
let cleaned = try await manager.process(mic: mic, reference: reference)
let runSeconds = Date().timeIntervalSince(runStart)

let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(cleaned.count))!
buffer.frameLength = AVAudioFrameCount(cleaned.count)
cleaned.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: cleaned.count) }
let file = try AVAudioFile(forWriting: URL(fileURLWithPath: arguments[3]), settings: format.settings)
try file.write(from: buffer)

let audioSeconds = Double(mic.count) / 16000
print("{\"audioSeconds\": \(audioSeconds), \"loadSeconds\": \(loadSeconds), \"runSeconds\": \(runSeconds), \"timesRealtime\": \(audioSeconds / runSeconds)}")
