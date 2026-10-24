import AVFoundation
import Foundation

// usage: echofold <words.json> <mic.wav> <others.wav>   words.json: {"mic": [{text,startMs,endMs}], "others": [...]}
struct InWord: Decodable { let text: String; let startMs: Int; let endMs: Int }
struct InWords: Decodable { let mic: [InWord]; let others: [InWord] }
struct Out: Encodable { let verdict: String; let showsEcho: Bool; let keptMic: [Int]; let keptOthers: [Int]; let droppedFromMic: Int; let droppedFromOthers: Int }

func envelope(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    return EchoBleedDetector.rmsEnvelope(pcm, sampleRate: Int(file.processingFormat.sampleRate), hz: 100)
}
func words(_ list: [InWord]) -> [Transcriber.Word] {
    list.map { Transcriber.Word(text: $0.text, confidence: 1, start: .milliseconds($0.startMs), end: .milliseconds($0.endMs)) }
}

let args = CommandLine.arguments
let input = try JSONDecoder().decode(InWords.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let mic = try envelope(args[2]), others = try envelope(args[3])
let verdict = EchoVerdict.verdict(EchoBleedDetector.analyse(micEnvelope: mic, othersEnvelope: others, envelopeHz: 100))
let shows = EchoLag.read(micEnvelope: mic, othersEnvelope: others, envelopeHz: 100).showsEcho
let micWords = words(input.mic), othersWords = words(input.others)
let folded = EchoFold.fold(mic: micWords, others: othersWords, micEnvelope: mic, othersEnvelope: others, envelopeHz: 100)
func kept(_ original: [Transcriber.Word], _ remaining: [Transcriber.Word]) -> [Int] {
    var out: [Int] = [], cursor = 0
    for (i, w) in original.enumerated() where cursor < remaining.count && remaining[cursor] == w { out.append(i); cursor += 1 }
    return out
}
let out = Out(verdict: "\(verdict)", showsEcho: shows, keptMic: kept(micWords, folded.mic), keptOthers: kept(othersWords, folded.others), droppedFromMic: folded.droppedFromMic, droppedFromOthers: folded.droppedFromOthers)
print(String(data: try JSONEncoder().encode(out), encoding: .utf8)!)
