import AVFoundation
import FluidAudio
import Foundation

// usage: fluidstream <left> <chunk> <right> <items.json> <out.json>
// Streams each recording through StreamingUnifiedAsrManager in 100 ms buffers,
// processing whatever complete chunks exist after each buffer, as a live
// dictation would. Reports the time finish() takes after the last buffer (the
// wait after the user lets go) and whether processing kept pace with the audio.
struct Item: Decodable { let id: String; let path: String }
struct Out: Encodable { let id: String; let text: String; let finishMs: Double; let busyMs: Double; let audioMs: Double; let worstStepMs: Double }

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

func pcm(of url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: inBuf)
    let converter = AVAudioConverter(from: file.processingFormat, to: target)!
    let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * 16000 / file.processingFormat.sampleRate) + 1024
    let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap)!
    var fed = false
    var err: NSError?
    converter.convert(to: outBuf, error: &err) { _, status in
        if fed { status.pointee = .endOfStream; return nil }
        fed = true; status.pointee = .haveData; return inBuf
    }
    if let err { throw err }
    return Array(UnsafeBufferPointer(start: outBuf.floatChannelData![0], count: Int(outBuf.frameLength)))
}

let args = CommandLine.arguments
guard args.count == 6, let l = Int(args[1]), let c = Int(args[2]), let r = Int(args[3]) else {
    print("usage: fluidstream <left> <chunk> <right> <items.json> <out.json>"); exit(64)
}
let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
let asr = StreamingUnifiedAsrManager(config: UnifiedConfig(leftFrames: l, chunkFrames: c, rightFrames: r), encoderPrecision: .int8)
let loadStart = ContinuousClock.now
try await asr.loadModels()
print(String(format: "models loaded in %.1f s ([%d,%d,%d])", ms(ContinuousClock.now - loadStart) / 1000, l, c, r))

let bufferSamples = 1600
func buffer(_ samples: ArraySlice<Float>) -> AVAudioPCMBuffer {
    let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    b.frameLength = AVAudioFrameCount(samples.count)
    samples.withUnsafeBufferPointer { src in b.floatChannelData![0].update(from: src.baseAddress!, count: samples.count) }
    return b
}

// Warm-up on silence so the first item does not pay for CoreML specialisation.
try await asr.reset()
try await asr.appendAudio(buffer([Float](repeating: 0, count: 48000)[...]))
try await asr.processBufferedAudio()
_ = try await asr.finish()

var outs: [Out] = []
for (n, item) in items.enumerated() {
    let samples = try pcm(of: URL(fileURLWithPath: item.path))
    try await asr.reset()
    var busy = 0.0, worst = 0.0
    var i = 0
    while i < samples.count {
        let end = min(i + bufferSamples, samples.count)
        try await asr.appendAudio(buffer(samples[i..<end]))
        let t = ContinuousClock.now
        try await asr.processBufferedAudio()
        let step = ms(ContinuousClock.now - t)
        busy += step; worst = max(worst, step)
        i = end
    }
    let t0 = ContinuousClock.now
    let text = try await asr.finish()
    let finish = ms(ContinuousClock.now - t0)
    outs.append(Out(id: item.id, text: text, finishMs: finish, busyMs: busy, audioMs: Double(samples.count) / 16, worstStepMs: worst))
    if n % 25 == 0 { print("\(n)/\(items.count)  finish \(Int(finish)) ms  \(text.prefix(70))") }
}
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(outs).write(to: URL(fileURLWithPath: args[5]))
let f = outs.map(\.finishMs).sorted()
let pace = outs.map { $0.busyMs / $0.audioMs }.sorted()
print(String(format: "finish: p50 %.0f ms, p95 %.0f, mean %.0f; processing while speaking: %.3f of real time (p50), %.3f (max); worst single step %.0f ms",
             f[f.count / 2], f[min(f.count - 1, f.count * 95 / 100)], f.reduce(0, +) / Double(f.count), pace[pace.count / 2], pace.last!, outs.map(\.worstStepMs).max()!))
