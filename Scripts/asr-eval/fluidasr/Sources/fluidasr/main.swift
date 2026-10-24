import AVFoundation
import CoreML
import FluidAudio
import Foundation

// items.json: [{"id", "path"}]. Writes {"clips": [{"id","text","ms","audioSeconds"}], "loadSeconds", "peakBytes"}.
// Long files go through FluidAudio's own disk-backed chunking (ASRConfig.streamingThreshold).
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

let arguments = CommandLine.arguments
guard arguments.count == 4, ["ultra", "phonon2", "unified", "local", "bark-pro"].contains(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: fluidasr <ultra|phonon2|unified|local|bark-pro> <items.json> <out.json>\n".utf8))
    exit(2)
}
let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))

if arguments[1] == "unified" {
    let loadStart = ContinuousClock.now
    let unified = UnifiedAsrManager(encoderPrecision: .int8)
    try await unified.loadModels()
    _ = try await unified.transcribe([Float](repeating: 0, count: 16000))
    let loadSeconds = seconds(ContinuousClock.now - loadStart)
    var clips: [ClipOut] = []
    for item in items {
        let samples = try pcm(of: URL(fileURLWithPath: item.path))
        let start = ContinuousClock.now
        let text = try await unified.transcribe(samples)
        let elapsed = seconds(ContinuousClock.now - start)
        clips.append(ClipOut(id: item.id, text: text, ms: elapsed * 1000, audioSeconds: Double(samples.count) / 16000))
    }
    try JSONEncoder().encode(RunOut(clips: clips, loadSeconds: loadSeconds, peakBytes: peakResidentBytes())).write(to: URL(fileURLWithPath: arguments[3]))
    exit(0)
}
// `local` loads Parakeet v3-layout models from FLUIDASR_MODEL_DIR (community weights). A folder of
// .mlpackage files (Orukeet's bundle) is compiled once into <folder>/compiled and loaded from there.
let version: AsrModelVersion = ["ultra": .ultra, "phonon2": .phonon2, "local": .v3, "bark-pro": .ultra][arguments[1]]!

func compiledFolder(_ folder: URL) throws -> URL {
    let packages = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".mlpackage") }
    if packages.isEmpty { return folder }
    let compiled = folder.appendingPathComponent("compiled")
    try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
    for package in packages {
        let destination = compiled.appendingPathComponent(package.replacingOccurrences(of: ".mlpackage", with: ".mlmodelc"))
        if FileManager.default.fileExists(atPath: destination.path) { continue }
        let temporary = try MLModel.compileModel(at: folder.appendingPathComponent(package))
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    let vocabulary = compiled.appendingPathComponent("parakeet_vocab.json")
    if !FileManager.default.fileExists(atPath: vocabulary.path) {
        try FileManager.default.copyItem(at: folder.appendingPathComponent("parakeet_vocab.json"), to: vocabulary)
    }
    return compiled
}

// `bark-pro` runs Underdog Bark 3.0 Pro the way its own runner (runtime/coreml/Sources/main.swift in the
// model repo) does: the encoder package holds two functions sharing weights, `short8` for audio up to
// 8 s and `full15` for longer, on the Neural Engine; the other three models on the CPU; 0.25 s of
// silence in front of every clip. Each function is loaded the first time a clip needs it.
if arguments[1] == "bark-pro" {
    guard let modelDir = ProcessInfo.processInfo.environment["FLUIDASR_MODEL_DIR"] else {
        FileHandle.standardError.write(Data("bark-pro needs FLUIDASR_MODEL_DIR\n".utf8))
        exit(2)
    }
    let barkLeadIn = 4000
    let barkShortLimit = 128000
    let loadStart = ContinuousClock.now
    let compiled = try compiledFolder(URL(fileURLWithPath: modelDir))
    func barkModel(_ name: String, _ units: MLComputeUnits, function: String? = nil) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        configuration.functionName = function
        return try MLModel(contentsOf: compiled.appendingPathComponent(name + ".mlmodelc"), configuration: configuration)
    }
    let rawVocabulary = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: compiled.appendingPathComponent("parakeet_vocab.json")))
    let vocabulary = Dictionary(uniqueKeysWithValues: rawVocabulary.compactMap { key, piece in Int(key).map { ($0, piece) } })
    let preprocessor = try barkModel("Preprocessor", .cpuOnly)
    let decoder = try barkModel("Decoder", .cpuOnly)
    let joint = try barkModel("JointDecisionv3", .cpuOnly)
    let cpuConfiguration = MLModelConfiguration()
    cpuConfiguration.computeUnits = .cpuOnly
    var managers: [String: AsrManager] = [:]
    func manager(for function: String) async throws -> AsrManager {
        if let loaded = managers[function] { return loaded }
        let models = AsrModels(encoder: try barkModel("Encoder", .cpuAndNeuralEngine, function: function), preprocessor: preprocessor,
                               decoder: decoder, joint: joint, configuration: cpuConfiguration, vocabulary: vocabulary, version: .ultra)
        let loaded = AsrManager(models: models)
        var warmState = try TdtDecoderState()
        _ = try await loaded.transcribe([Float](repeating: 0, count: 16000), decoderState: &warmState)
        managers[function] = loaded
        return loaded
    }
    _ = try await manager(for: "short8")
    let loadSeconds = seconds(ContinuousClock.now - loadStart)
    var clips: [ClipOut] = []
    for item in items {
        let audio = try pcm(of: URL(fileURLWithPath: item.path))
        let samples = [Float](repeating: 0, count: barkLeadIn) + audio
        let barkManager = try await manager(for: samples.count <= barkShortLimit ? "short8" : "full15")
        var state = try TdtDecoderState()
        let start = ContinuousClock.now
        let result = try await barkManager.transcribe(samples, decoderState: &state)
        let elapsed = seconds(ContinuousClock.now - start)
        clips.append(ClipOut(id: item.id, text: result.text, ms: elapsed * 1000, audioSeconds: Double(audio.count) / 16000))
    }
    try JSONEncoder().encode(RunOut(clips: clips, loadSeconds: loadSeconds, peakBytes: peakResidentBytes())).write(to: URL(fileURLWithPath: arguments[3]))
    exit(0)
}

let loadStart = ContinuousClock.now
let models: AsrModels
if arguments[1] == "local" {
    guard let modelDir = ProcessInfo.processInfo.environment["FLUIDASR_MODEL_DIR"] else {
        FileHandle.standardError.write(Data("local needs FLUIDASR_MODEL_DIR\n".utf8))
        exit(2)
    }
    models = try AsrModels.loadLocal(from: try compiledFolder(URL(fileURLWithPath: modelDir)), version: version)
} else {
    models = try await AsrModels.downloadAndLoad(version: version)
}
let manager = AsrManager(config: .default)
try await manager.loadModels(models)
var warmState = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
_ = try await manager.transcribe([Float](repeating: 0, count: 16000), decoderState: &warmState)
let loadSeconds = seconds(ContinuousClock.now - loadStart)

var clips: [ClipOut] = []
for item in items {
    var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
    let start = ContinuousClock.now
    let result = try await manager.transcribe(URL(fileURLWithPath: item.path), decoderState: &state)
    let elapsed = seconds(ContinuousClock.now - start)
    clips.append(ClipOut(id: item.id, text: result.text, ms: elapsed * 1000, audioSeconds: result.duration))
}
let output = RunOut(clips: clips, loadSeconds: loadSeconds, peakBytes: peakResidentBytes())
try JSONEncoder().encode(output).write(to: URL(fileURLWithPath: arguments[3]))
