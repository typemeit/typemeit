import AVFoundation
import FluidAudio
import Foundation

// usage: fluidtest <int8|fp16> <plain|boost> <items.json> <out.json>
// items.json: [{"id": "...", "path": "...wav|m4a", "vocab": ["term", ...]}]
// Transcribes every item with FluidAudio's parakeet-unified, optionally with
// that item's vocabulary boosted, and writes [{"id", "text", "ms"}].

struct Item: Decodable { let id: String; let path: String; let vocab: [String]? }
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

let args = CommandLine.arguments
guard args.count == 5 else { print("usage: fluidtest <int8|fp16> <plain|boost> <items.json> <out.json>"); exit(64) }
let precision: UnifiedEncoderPrecision = args[1] == "fp16" ? .fp16 : .int8
let boost = args[2] == "boost"
let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: args[3])))

let loadStart = ContinuousClock.now
let asr = UnifiedAsrManager(encoderPrecision: precision)
try await asr.loadModels()
let ctc: CtcModels? = boost ? try await CtcModels.downloadAndLoad() : nil
print(String(format: "models loaded in %.1f s (%@, %@)", ms(ContinuousClock.now - loadStart) / 1000, args[1], args[2]))

// Warm-up: the first call pays for CoreML specialisation.
_ = try await asr.transcribe([Float](repeating: 0, count: 16000))

var outs: [Out] = []
for (n, item) in items.enumerated() {
    let samples = try pcm(of: URL(fileURLWithPath: item.path))
    if let ctc {
        let terms = (item.vocab ?? []).map { CustomVocabularyTerm(text: $0) }
        let env = ProcessInfo.processInfo.environment
        func f(_ k: String, _ d: Float) -> Float { env[k].flatMap(Float.init) ?? d }
        func n(_ k: String, _ d: Int) -> Int { env[k].flatMap(Int.init) ?? d }
        let context = CustomVocabularyContext(terms: terms, minSimilarity: f("FA_MINSIM", 0.52), minCombinedConfidence: f("FA_MINCONF", 0.54), minTermLength: n("FA_MINLEN", 3))
        let rescorer = VocabularyRescorer.Config(
            shortTermCbwTaperPivot: n("FA_TAPER", 0),
            spotterRescueMinSimilarity: f("FA_RESCUE_SIM", 0.30),
            spotterRescueMultiWordMinSimilarity: f("FA_RESCUE_MULTI", 0.50),
            spotterRescueEnabled: env["FA_RESCUE"] != "0")
        try await asr.configureVocabularyBoosting(vocabulary: context, ctcModels: ctc, config: rescorer)
    }
    let t0 = ContinuousClock.now
    let text = try await asr.transcribe(samples)
    let dt = ms(ContinuousClock.now - t0)
    outs.append(Out(id: item.id, text: text, ms: dt, audioMs: Double(samples.count) / 16))
    if n % 25 == 0 { print("\(n)/\(items.count)  \(Int(dt)) ms  \(text.prefix(80))") }
}
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(outs).write(to: URL(fileURLWithPath: args[4]))
let times = outs.map(\.ms).sorted()
print(String(format: "done: %d items, p50 %.0f ms, p95 %.0f ms, mean %.0f ms", outs.count, times[times.count / 2], times[min(times.count - 1, times.count * 95 / 100)], times.reduce(0, +) / Double(times.count)))
