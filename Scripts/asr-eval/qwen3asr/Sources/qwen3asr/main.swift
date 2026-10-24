import AVFoundation
import FluidAudio
import Foundation

// items.json: [{"id", "path"}]. Writes {"clips": [{"id","text","ms","audioSeconds"}], "loadSeconds", "peakBytes"}.
// Every clip is cut into fixed chunkSeconds windows: the decoder's cache holds 512 tokens, prompt included, so a 40 s clip fails.
struct Item: Decodable { let id: String; let path: String }
struct ClipOut: Encodable { let id: String; let text: String; let ms: Double; let audioSeconds: Double }
struct RunOut: Encodable { let clips: [ClipOut]; let loadSeconds: Double; let peakBytes: Int }

func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

func peakResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

func pcm(of url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: inBuf)
    if file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1, file.processingFormat.commonFormat == .pcmFormatFloat32 {
        return Array(UnsafeBufferPointer(start: inBuf.floatChannelData![0], count: Int(inBuf.frameLength)))
    }
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

let chunkSeconds = 20
let arguments = CommandLine.arguments
guard arguments.count == 5, let variant = Qwen3AsrVariant(rawValue: arguments[1]) else { fputs("usage: qwen3asr <f32|int8> <dictation|meeting> <items.json> <out.json>\n", stderr); exit(2) }
let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[3])))

let loadStart = ContinuousClock.now
let manager = Qwen3AsrManager()
try await manager.loadModels(from: try await Qwen3AsrModels.download(variant: variant))
_ = try await manager.transcribe(audioSamples: [Float](repeating: 0, count: 16000), language: "English", maxNewTokens: 8)
let loadSeconds = seconds(ContinuousClock.now - loadStart)

var clips: [ClipOut] = []
for item in items {
    let samples = try pcm(of: URL(fileURLWithPath: item.path))
    let start = ContinuousClock.now
    var texts: [String] = []
    let window = chunkSeconds * 16000
    var offset = 0
    while offset < samples.count {
        let chunk = Array(samples[offset..<min(offset + window, samples.count)])
        offset += window
        guard chunk.count >= 1600 else { continue }
        texts.append(try await manager.transcribe(audioSamples: chunk, language: "English", maxNewTokens: 200))
    }
    let elapsed = seconds(ContinuousClock.now - start)
    clips.append(ClipOut(id: item.id, text: texts.joined(separator: " "), ms: elapsed * 1000, audioSeconds: Double(samples.count) / 16000))
}
try JSONEncoder().encode(RunOut(clips: clips, loadSeconds: loadSeconds, peakBytes: peakResidentBytes())).write(to: URL(fileURLWithPath: arguments[4]))
