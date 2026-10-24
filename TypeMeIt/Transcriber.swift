import FluidAudio
import Foundation

/// Parakeet Ultra on the Neural Engine through FluidAudio's Core ML build.
/// One model, loaded on first use and kept for the life of the app. Runs
/// are serialised here, one at a time, whichever of dictation or a meeting
/// chunk asks: the manager is an actor, but a run suspends the caller, and
/// two interleaved runs would share its caches.
actor Transcriber {
    static let shared = Transcriber()

    private var manager: AsrManager?
    private let abortFlag = AbortFlag()
    private let meetingAbortFlag = AbortFlag()
    /// Callers waiting for the run in flight, in order.
    private var runWaiters: [CheckedContinuation<Void, Never>] = []
    private var running = false

    final class AbortFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
        func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    enum Error: Swift.Error, LocalizedError {
        case aborted
        var errorDescription: String? { "Transcription cancelled" }
    }

    private init() {}

    private func ensureLoaded() async throws -> AsrManager {
        if let manager { return manager }
        let started = ContinuousClock.now
        let models = try AsrModels.loadLocal(from: ModelStore.directory, version: .ultra)
        let readFromDisk = ContinuousClock.now - started
        let loaded = AsrManager(config: .default)
        try await loaded.loadModels(models)
        let loadedIntoCoreML = ContinuousClock.now - started - readFromDisk
        // The first run on a fresh load compiles for the Neural Engine, which
        // takes seconds; done here, the first dictation does not pay for it.
        var state = try TdtDecoderState(decoderLayers: await loaded.decoderLayerCount)
        _ = try? await loaded.transcribe([Float](repeating: 0, count: Int(AudioCapture.targetFormat.sampleRate)), decoderState: &state)
        manager = loaded
        Log.transcriber.info("Model loaded in \(ContinuousClock.now - started)")
        let total = ContinuousClock.now - started
        DebugLog.write("Speech model loaded in \(total.milliseconds) ms: \(readFromDisk.milliseconds) ms reading, \(loadedIntoCoreML.milliseconds) ms in Core ML, \((total - readFromDisk - loadedIntoCoreML).milliseconds) ms first run")
        await ModelStore.shared.modelLoaded()
        return loaded
    }

    func preload() async {
        await acquire()
        defer { release() }
        do { _ = try await ensureLoaded() } catch { Log.transcriber.error("Preload failed: \(error.localizedDescription)") }
    }

    /// One word of a transcript with how sure the model was of it.
    struct Word: Sendable, Equatable, Codable {
        let text: String
        /// The lowest per-token probability among the word's tokens, as the
        /// decoder reports it for each token it emits: a confidence hint,
        /// not a calibrated probability. NaN when the model produced none.
        let confidence: Float
        let start: Duration
        let end: Duration
    }

    struct Transcript: Sendable {
        let text: String
        /// Empty when the model returned no token timings.
        let words: [Word]

        init(text: String, words: [Word]) {
            self.text = text
            self.words = words
        }

        /// Text is the words joined by single spaces, which keeps
        /// `text.split(whereSeparator: \.isWhitespace)` and `words` one to one.
        init(words: [Word]) {
            self.words = words
            text = words.map(\.text).joined(separator: " ")
        }

        /// Text without word rows.
        init(text: String) {
            self.text = text
            words = []
        }

        /// The text split on whitespace with confidence attached where the
        /// word rows line up with it one to one; otherwise every word is
        /// unknown, which the matcher treats as uncertain.
        var matcherWords: [CustomWordMatcher.Word] {
            let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count == words.count, zip(parts, words).allSatisfy({ $0 == $1.text }) else {
                return parts.map { CustomWordMatcher.Word(text: $0, confidence: nil) }
            }
            return zip(parts, words).map { CustomWordMatcher.Word(text: $0, confidence: $1.confidence.isNaN ? nil : $1.confidence) }
        }
    }

    /// One token the decoder emitted, as FluidAudio's `TokenTiming` reports it:
    /// the piece, with a leading space when it starts a word.
    struct Token: Sendable, Equatable {
        let text: String
        let confidence: Float
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Words from tokens. A word starts at a token with a leading space (or a
    /// space inside it) and runs to the next one; its time is the first
    /// token's start to the last token's end, and its confidence the lowest
    /// of its tokens'. Blank and padding pieces are dropped.
    static func words(from tokens: [Token]) -> [Word] {
        struct Open {
            var text: String
            var confidence: Float
            var start: TimeInterval
            var end: TimeInterval
        }
        var words: [Word] = []
        var open: Open?
        var boundary = true
        func close() {
            guard let finished = open else { return }
            words.append(Word(text: finished.text, confidence: finished.confidence, start: .seconds(finished.start), end: .seconds(finished.end)))
            open = nil
        }
        func lowest(_ a: Float, _ b: Float) -> Float { a.isNaN ? b : b.isNaN ? a : min(a, b) }
        for token in tokens where !token.text.isEmpty && token.text != "<blank>" && token.text != "<pad>" {
            if token.text.first?.isWhitespace == true { boundary = true }
            for (index, piece) in token.text.split(whereSeparator: \.isWhitespace).enumerated() {
                if index > 0 { boundary = true }
                if boundary { close() }
                boundary = false
                if var current = open {
                    current.text += piece
                    current.confidence = lowest(current.confidence, token.confidence)
                    current.end = token.end
                    open = current
                } else {
                    open = Open(text: String(piece), confidence: token.confidence, start: token.start, end: token.end)
                }
            }
            if token.text.last?.isWhitespace == true { boundary = true }
        }
        close()
        return words
    }

    /// pcm: mono Float32 at 16 kHz.
    func transcribe(_ pcm: [Float]) async throws -> String {
        try await transcribeScored(pcm).text
    }

    /// A dictation of any length: FluidAudio cuts what is longer than the
    /// model's window itself and keeps its memory flat.
    func transcribeScored(_ pcm: [Float]) async throws -> Transcript {
        abortFlag.set(false)
        let started = ContinuousClock.now
        let transcript = try await run(pcm, abort: abortFlag)
        Log.transcriber.info("Transcribed \(pcm.count / 16000) s of audio in \(ContinuousClock.now - started)")
        return transcript
    }

    nonisolated func cancel() { abortFlag.set(true) }

    // MARK: Meetings

    /// A meeting chunk. `pcm` is 16 kHz mono Float32, at most
    /// `Fixed.meetingChunkSeconds` long. Dictation waits at most one chunk.
    func transcribeMeetingChunk(_ pcm: [Float]) async throws -> Transcript {
        meetingAbortFlag.set(false)
        let started = ContinuousClock.now
        let transcript = try await run(pcm, abort: meetingAbortFlag)
        Log.transcriber.info("Meeting chunk: \(pcm.count / 16000) s of audio in \(ContinuousClock.now - started)")
        DebugLog.write("Meeting chunk: \(pcm.count / 16000) s of audio in \((ContinuousClock.now - started).milliseconds) ms")
        return transcript
    }

    /// Stops the meeting chunk in flight, and only that: a run cannot be
    /// interrupted, so the flag discards its result when it returns.
    nonisolated func cancelMeeting() { meetingAbortFlag.set(true) }

    // MARK: Running

    private func run(_ pcm: [Float], abort flag: AbortFlag) async throws -> Transcript {
        let asked = ContinuousClock.now
        await acquire()
        defer { release() }
        let queued = ContinuousClock.now - asked
        if queued > Fixed.slowTranscriberWait { DebugLog.write("Transcription waited \(queued.milliseconds) ms for the speech model's turn") }
        if flag.get() { throw Error.aborted }
        let loaded = try await ensureLoaded()
        var state = try TdtDecoderState(decoderLayers: await loaded.decoderLayerCount)
        let result: ASRResult
        do {
            result = try await loaded.transcribe(pcm, decoderState: &state)
        } catch ASRError.invalidAudioData {
            // Shorter than the model's minimum: nothing was said.
            return Transcript(words: [])
        }
        if flag.get() { throw Error.aborted }
        guard let timings = result.tokenTimings else { return Transcript(text: result.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Transcript(words: Transcriber.words(from: timings.map { Token(text: $0.token, confidence: $0.confidence, start: $0.startTime, end: $0.endTime) }))
    }

    private func acquire() async {
        guard running else { running = true; return }
        await withCheckedContinuation { runWaiters.append($0) }
    }

    private func release() {
        if runWaiters.isEmpty { running = false } else { runWaiters.removeFirst().resume() }
    }
}
