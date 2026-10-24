import AVFoundation
import Foundation

// usage: appasr <dictation|meeting> <items.json> <out.json> [--terms terms.json] [--boost] [--matcher] [--repeat N] [--dump-words]
//        appasr rematch <words-run.json> <out.json> --terms terms.json   (CustomWordMatcher over words saved by --dump-words, no speech model;
//        thresholds from the TUNE_* environment variables the scratch copy of the matcher reads)
//   terms.json: [{"text","aliases"}], the custom words. --boost: FluidAudio CTC vocabulary boosting inside the Transcriber
//   (needs --terms); --matcher: CustomWordMatcher over the finished text, as Pipeline does for a dictation. --repeat N times each clip N
//   times (text from the first pass, ms the median) and warms the CTC model first.
// items.json: [{"id", "path"}], 16 kHz mono WAV. Writes {"clips": [{"id","text","ms","audioSeconds"}], "loadSeconds", "peakBytes"}.
//   dictation: the whole file through Transcriber.transcribeScored, as Pipeline does for a dictation.
//   meeting:   ChunkCutter cuts, the silence skip, the quiet retry, the longest-word trim and ChunkStitch,
//              as MeetingTranscriber.run does for one track.
// The model comes from TYPEMEIT_ASR_DIR, else the app's own models/asr/<version> folder.
struct Item: Decodable { let id: String; let path: String }
/// The dictionary check the app passes (TUNE_DICT=0 leaves it out, to compare).
let dictionary: (String) -> Bool = ProcessInfo.processInfo.environment["TUNE_DICT"] == "0" ? { _ in false } : { word in MainActor.assumeIsolated { EnglishWord.isKnown(word) } }
struct WordOut: Codable { let t: String; let c: Float? }
struct ClipOut: Encodable { let id: String; let text: String; let ms: Double; let audioSeconds: Double; let matcherMs: Double; var words: [WordOut]? = nil }
struct TermIn: Decodable { let text: String; let aliases: [String] }
struct RunOut: Encodable { let clips: [ClipOut]; let loadSeconds: Double; let peakBytes: Int; let rescoreMs: [Double] }

func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18 }

func peakResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

func samples(of url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

/// MeetingTranscriber.transcribe / transcribeRetryingQuiet for one chunk.
func chunkWords(_ chunk: [Float], range: Range<Int>) async throws -> [Transcriber.Word] {
    func run(_ pcm: [Float], offsetMs: Int) async -> [Transcriber.Word] {
        do {
            let transcript = try await Transcriber.shared.transcribeMeetingChunk(pcm)
            let offset = Duration.milliseconds(offsetMs)
            return transcript.words.map { Transcriber.Word(text: $0.text, confidence: $0.confidence, start: $0.start + offset, end: $0.end + offset) }
        } catch {
            return [Transcriber.Word(text: "[unreadable]", confidence: .nan, start: .milliseconds(range.lowerBound), end: .milliseconds(range.upperBound))]
        }
    }
    let words = await run(chunk, offsetMs: range.lowerBound)
    guard words.isEmpty, QuietSpeech.hasSpeech(chunk), let boosted = QuietSpeech.boosted(chunk) else { return words }
    return await run(boosted.pcm, offsetMs: range.lowerBound + boosted.offsetFrames / 16)
}

func meetingWords(_ pcm: [Float]) async throws -> [Transcriber.Word] {
    let envelopeMs = MeetingTranscriber.peakEnvelopeMs
    let peaks = ChunkCutter.peaks(of: pcm, frameSamples: 16 * envelopeMs)
    let cuts = ChunkCutter.cuts(peaks: peaks, frameMs: envelopeMs, maxChunkMs: Fixed.meetingChunkSeconds * 1000,
                                overlapMs: Fixed.meetingChunkOverlapSeconds * 1000, searchMs: Fixed.meetingChunkSearchSeconds * 1000)
    var words: [Transcriber.Word] = []
    for range in cuts {
        let frames = peaks[(range.lowerBound / envelopeMs)..<min(peaks.count, (range.upperBound + envelopeMs - 1) / envelopeMs)]
        var transcribed: [Transcriber.Word] = []
        if (frames.max() ?? 0) >= Fixed.meetingSilenceFloor {
            transcribed = try await chunkWords(Array(pcm[min(range.lowerBound * 16, pcm.count)..<min(range.upperBound * 16, pcm.count)]), range: range)
        }
        let longest = Duration.milliseconds(Fixed.meetingLongestWordMs)
        let trimmed = transcribed.map { Transcriber.Word(text: $0.text, confidence: $0.confidence, start: $0.start, end: min($0.end, $0.start + longest)) }
        words = ChunkStitch.append(trimmed, after: words, overlapMs: Fixed.meetingChunkOverlapSeconds * 1000)
    }
    return words
}

func meetingText(_ pcm: [Float]) async throws -> String {
    try await meetingWords(pcm).map(\.text).joined(separator: " ")
}

var arguments = CommandLine.arguments
if arguments.count > 1, arguments[1] == "rematch" {
    guard let at = arguments.firstIndex(of: "--terms"), at + 1 < arguments.count, arguments.count >= 5 else { exit(2) }
    struct Saved: Decodable { let clips: [SavedClip] }
    struct SavedClip: Decodable { let id: String; let words: [WordOut] }
    let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
    let rematchTerms = try JSONDecoder().decode([TermIn].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[at + 1]))).map { CustomWordMatcher.Term($0.text, aliases: $0.aliases) }
    let rematched = saved.clips.map { clip in
        ClipOut(id: clip.id, text: CustomWordMatcher.apply(clip.words.map { CustomWordMatcher.Word(text: $0.t, confidence: $0.c) }, terms: rematchTerms, isKnownWord: dictionary).text, ms: 0, audioSeconds: 0, matcherMs: 0)
    }
    try JSONEncoder().encode(RunOut(clips: rematched, loadSeconds: 0, peakBytes: 0, rescoreMs: [])).write(to: URL(fileURLWithPath: arguments[3]))
    exit(0)
}
func option(_ name: String, takesValue: Bool) -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    let value = takesValue && index + 1 < arguments.count ? arguments[index + 1] : ""
    arguments.removeSubrange(index...(takesValue ? min(index + 1, arguments.count - 1) : index))
    return value
}
let termsPath = option("--terms", takesValue: true)
let boost = option("--boost", takesValue: false) != nil
let matcher = option("--matcher", takesValue: false) != nil
let dumpWords = option("--dump-words", takesValue: false) != nil
let repeats = Int(option("--repeat", takesValue: true) ?? "") ?? 1
guard arguments.count == 4, ["dictation", "meeting"].contains(arguments[1]), (!boost && !matcher) || termsPath != nil else {
    FileHandle.standardError.write(Data("usage: appasr <dictation|meeting> <items.json> <out.json> [--terms terms.json] [--boost] [--matcher] [--repeat N]\n".utf8))
    exit(2)
}
let meeting = arguments[1] == "meeting"
let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: arguments[2])))
let terms = try termsPath.map { try JSONDecoder().decode([TermIn].self, from: Data(contentsOf: URL(fileURLWithPath: $0))).map { CustomWordMatcher.Term($0.text, aliases: $0.aliases) } } ?? []

let loadStart = ContinuousClock.now
await Transcriber.shared.preload()
if boost { try await Boost.load(terms: terms) }
let loadSeconds = seconds(ContinuousClock.now - loadStart)

func transcript(_ pcm: [Float]) async throws -> String {
    meeting ? try await meetingText(pcm) : try await Transcriber.shared.transcribeScored(pcm).text
}

func dumped(_ pcm: [Float]) async throws -> [WordOut] {
    if meeting { return try await meetingWords(pcm).map { WordOut(t: $0.text, c: $0.confidence.isNaN ? nil : $0.confidence) } }
    return try await Transcriber.shared.transcribeScored(pcm).matcherWords.map { WordOut(t: $0.text, c: $0.confidence) }
}

var clips: [ClipOut] = []
if let first = items.first, repeats > 1 || boost { _ = try await transcript(try samples(of: URL(fileURLWithPath: first.path))) }
Boost.rescoreMs = []
for item in items {
    let pcm = try samples(of: URL(fileURLWithPath: item.path))
    var text = "", times: [Double] = [], matcherTimes: [Double] = []
    for pass in 0..<max(1, repeats) {
        let start = ContinuousClock.now
        var result: String
        if matcher && !meeting {
            let heard = try await Transcriber.shared.transcribeScored(pcm)
            let matchStart = ContinuousClock.now
            result = CustomWordMatcher.apply(heard.matcherWords, terms: terms, isKnownWord: dictionary).text
            matcherTimes.append(seconds(ContinuousClock.now - matchStart) * 1000)
        } else {
            if matcher {
                let heard = try await meetingWords(pcm)
                result = CustomWordMatcher.apply(heard.map { CustomWordMatcher.Word(text: $0.text, confidence: $0.confidence.isNaN ? nil : $0.confidence) }, terms: terms, isKnownWord: dictionary).text
            } else {
                result = try await transcript(pcm)
            }
        }
        times.append(seconds(ContinuousClock.now - start) * 1000)
        if pass == 0 { text = result }
    }
    let median = times.sorted()[times.count / 2]
    clips.append(ClipOut(id: item.id, text: text, ms: median, audioSeconds: Double(pcm.count) / 16000, matcherMs: matcherTimes.isEmpty ? 0 : matcherTimes.sorted()[matcherTimes.count / 2], words: dumpWords ? try await dumped(pcm) : nil))
}
try JSONEncoder().encode(RunOut(clips: clips, loadSeconds: loadSeconds, peakBytes: peakResidentBytes(), rescoreMs: Boost.rescoreMs)).write(to: URL(fileURLWithPath: arguments[3]))
