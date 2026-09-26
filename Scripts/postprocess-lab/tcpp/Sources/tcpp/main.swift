import AVFoundation
import Foundation

// usage: tcpp <items.json> <out.json>  — same item format and output as fluidtest.
struct Item: Decodable { let id: String; let path: String }
struct Out: Encodable { let id: String; let text: String; let ms: Double; let audioMs: Double }

func ms(_ d: Duration) -> Double { Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }

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

let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let loadStart = ContinuousClock.now
await Transcriber.shared.preload()
print(String(format: "model loaded in %.1f s", ms(ContinuousClock.now - loadStart) / 1000))
_ = try await Transcriber.shared.transcribeScored([Float](repeating: 0, count: 16000))
var outs: [Out] = []
for (n, item) in items.enumerated() {
    let samples = try pcm(of: URL(fileURLWithPath: item.path))
    let t0 = ContinuousClock.now
    var text = ""
    if let window = ProcessInfo.processInfo.environment["TCPP_WINDOW_S"].flatMap(Double.init) {
        // Split at the quietest 100 ms near each window boundary, transcribe the pieces, join.
        var pieces: [String] = []
        var start = 0
        let maxLen = Int(window * 16000), hop = 1600
        while start < samples.count {
            var end = min(samples.count, start + maxLen)
            if end < samples.count {
                var best = end, bestEnergy = Float.greatestFiniteMagnitude
                var pos = start + maxLen * 2 / 3
                while pos + hop <= end {
                    let e = samples[pos..<(pos + hop)].reduce(0) { $0 + $1 * $1 }
                    if e < bestEnergy { bestEnergy = e; best = pos + hop / 2 }
                    pos += hop / 2
                }
                end = best
            }
            let t = try await Transcriber.shared.transcribeScored(Array(samples[start..<end]))
            if !t.text.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(t.text.trimmingCharacters(in: .whitespaces)) }
            start = end
        }
        text = pieces.joined(separator: " ")
    } else {
        text = try await Transcriber.shared.transcribeScored(samples).text
    }
    let dt = ms(ContinuousClock.now - t0)
    outs.append(Out(id: item.id, text: text, ms: dt, audioMs: Double(samples.count) / 16))
    if n % 25 == 0 { print("\(n)/\(items.count)  \(Int(dt)) ms  \(text.prefix(80))") }
}
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(outs).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
let times = outs.map(\.ms).sorted()
print(String(format: "done: %d items, p50 %.0f ms, p95 %.0f ms, mean %.0f ms", outs.count, times[times.count / 2], times[min(times.count - 1, times.count * 95 / 100)], times.reduce(0, +) / Double(times.count)))
