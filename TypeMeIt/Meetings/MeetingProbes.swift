import AVFoundation
import CoreAudio
import Foundation

/// The spikes in docs/meetings.md section 6, as launch arguments on the dev
/// app. Each writes to the debug log and to `Store.directory/Meetings/probe/`,
/// and goes once its pass/fail line in the spec is filled in.
///
///     -meetingProbe                         log every process object on every fire and every second (S1)
///     -meetingProbeCapture <bundle id> <s>  tap an app for <s> seconds beside the mic and log the tracks (S1)
///     -recordRoom <s>                       record the room for <s> seconds through the whole pipeline (7.1)
///     -transcribeFile <path>                whole-file against chunked on one CAF (S2)
///     -addSpeakers <meeting id>             run the pass again on a finished meeting with the diarizer (S3)
@MainActor
enum MeetingProbes {
    nonisolated static let directory = Store.directory.appendingPathComponent("Meetings", isDirectory: true).appendingPathComponent("probe", isDirectory: true)

    static func runIfAsked() {
        let args = CommandLine.arguments
        func value(after flag: String, _ offset: Int = 1) -> String? {
            guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
            return args[i + offset]
        }
        if args.contains("-meetingProbe") { probeProcesses() }
        if let bundle = value(after: "-meetingProbeCapture"), let seconds = value(after: "-meetingProbeCapture", 2).flatMap(Int.init) {
            probeCapture(bundleID: bundle, seconds: seconds)
        }
        if let seconds = value(after: "-recordRoom").flatMap(Int.init) { recordRoom(seconds: seconds) }
        if let path = value(after: "-transcribeFile") { transcribeFile(URL(fileURLWithPath: path)) }
        if let id = value(after: "-addSpeakers").flatMap(UUID.init) {
            DebugLog.enabled = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                MeetingCoordinator.shared.transcribeAgain(id)
            }
        }
    }

    // MARK: S1, detection

    private static var listener: AudioProcesses.Listener?
    private static var probeTimer: Timer?

    private static func probeProcesses() {
        DebugLog.enabled = true
        let queue = DispatchQueue(label: "it.typeme.typemeit.meeting-probe")
        listener = AudioProcesses.Listener(queue: queue) { why in
            let infos = AudioProcesses.snapshot()
            Task { @MainActor in logSnapshot(infos, why: why) }
        }
        probeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            let infos = AudioProcesses.snapshot()
            Task { @MainActor in logSnapshot(infos, why: "poll") }
        }
        DebugLog.write("Meeting probe: listening; the log is \(DebugLog.displayPath)")
    }

    private static var lastSnapshot = ""

    private static func logSnapshot(_ infos: [AudioProcessInfo], why: String) {
        let apps = ProcessOwner.runningApps()
        let lines = infos.filter { $0.input || $0.output }.map { info -> String in
            let owner = ProcessOwner.owner(of: info, apps: apps)
            return "  \(info.pid) \(info.bundleID ?? "-") \(info.path ?? "-") → \(owner?.name ?? "?") in=\(info.input) out=\(info.output)"
        }
        let text = lines.joined(separator: "\n")
        guard text != lastSnapshot || why != "poll" else { return }
        lastSnapshot = text
        DebugLog.write("Meeting probe (\(why)):\n\(text.isEmpty ? "  nobody" : text)")
    }

    // MARK: S1, capture

    private final class ProbeSink: MeetingCaptureSink, @unchecked Sendable {
        let mic: TrackWriter
        let others: TrackWriter?
        private var frames = 0
        private var second = 0
        private var micPeak: Float = 0
        private var othersPeak: Float = 0
        init(mic: TrackWriter, others: TrackWriter?) { self.mic = mic; self.others = others }

        func capture(_ capture: MeetingCapture, mic: [Float], others: [Float]?) {
            self.mic.append(mic)
            if let others { self.others?.append(others) }
            micPeak = max(micPeak, AudioCapture.peak(mic))
            othersPeak = max(othersPeak, AudioCapture.peak(others ?? []))
            frames += mic.count
            if frames >= Int(AudioCapture.targetFormat.sampleRate) {
                second += 1
                DebugLog.write("Meeting probe capture: second \(second) mic peak \(micPeak) others peak \(othersPeak) overrun-free")
                frames = 0; micPeak = 0; othersPeak = 0
            }
        }
        func captureGap(_ capture: MeetingCapture, frames: Int) { DebugLog.write("Meeting probe capture: gap \(frames) frames") }
        func captureFailed(_ capture: MeetingCapture, error: Error) { DebugLog.write("Meeting probe capture: failed \(error.localizedDescription)") }
    }

    private static var probeCapture: MeetingCapture?

    private static func probeCapture(bundleID: String, seconds: Int) {
        DebugLog.enabled = true
        let apps = ProcessOwner.runningApps()
        let holders = MeetingWatch.group(AudioProcesses.snapshot(), apps: apps)
        guard let holder = holders.first(where: { $0.owner.bundleID == bundleID }) ?? holders.first(where: { $0.owner.bundleID.hasPrefix(bundleID) }) else {
            DebugLog.write("Meeting probe capture: no process object with audio for \(bundleID); holders: \(MeetingWatch.describe(holders))")
            return
        }
        guard let mic = MeetingCapture.microphone(preferredUID: Settings.shared.microphoneUID) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sink = ProbeSink(mic: try TrackWriter(url: directory.appendingPathComponent("mic.caf")),
                                 others: try TrackWriter(url: directory.appendingPathComponent("others.caf")))
            let capture = try MeetingCapture(mic: mic, tapProcesses: holder.objectIDs, sink: sink)
            probeCapture = capture
            DebugLog.write("Meeting probe capture: tapping \(holder.owner.name) (\(holder.objectIDs)) for \(seconds) s; tap format \(capture.tapFormat.map { "\($0.mSampleRate) Hz \($0.mChannelsPerFrame) ch" } ?? "-"), aggregate \(capture.micFormat.mSampleRate) Hz")
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                DebugLog.write("Meeting probe capture: first host time \(capture.firstHostTime)")
                capture.stop()
                let m = sink.mic.finish()
                let o = sink.others?.finish()
                DebugLog.write("Meeting probe capture: mic \(m.frames) frames peak \(m.peak); others \(o?.frames ?? 0) frames peak \(o?.peak ?? 0); files in \(directory.path)")
                probeCapture = nil
            }
        } catch {
            DebugLog.write("Meeting probe capture: \(error.localizedDescription)")
        }
    }

    // MARK: 7.1, the room through the pipeline

    private static func recordRoom(seconds: Int) {
        DebugLog.enabled = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            MeetingCoordinator.shared.recordRoom()
            try? await Task.sleep(for: .seconds(seconds))
            MeetingCoordinator.shared.stopMeeting()
        }
    }

    // MARK: S2, long tracks

    private static func transcribeFile(_ url: URL) {
        DebugLog.enabled = true
        Task.detached {
            do {
                let file = try AVAudioFile(forReading: url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
                try file.read(into: buffer)
                let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                let seconds = pcm.count / Int(AudioCapture.targetFormat.sampleRate)

                var started = ContinuousClock.now
                let whole = try await Transcriber.shared.transcribeMeetingChunk(pcm)
                let wholeTime = ContinuousClock.now - started
                DebugLog.write("Meeting probe transcribe: whole file (\(seconds) s) in \(wholeTime), \(counted(whole.words.count, "word")), resident \(residentMB()) MB")

                let peakFrames = Int(AudioCapture.targetFormat.sampleRate) * MeetingTranscriber.peakEnvelopeMs / 1000
                let peaks = stride(from: 0, to: pcm.count, by: peakFrames).map { AudioCapture.peak(Array(pcm[$0..<min($0 + peakFrames, pcm.count)])) }
                let cuts = ChunkCutter.cuts(peaks: peaks, frameMs: MeetingTranscriber.peakEnvelopeMs, maxChunkMs: Fixed.meetingChunkSeconds * 1000,
                                            overlapMs: Fixed.meetingChunkOverlapSeconds * 1000, searchMs: Fixed.meetingChunkSearchSeconds * 1000)
                started = ContinuousClock.now
                var words: [Transcriber.Word] = []
                var longest: Duration = .zero
                for range in cuts {
                    let chunk = Array(pcm[(range.lowerBound * Meeting.framesPerMs)..<min(range.upperBound * Meeting.framesPerMs, pcm.count)])
                    let chunkStart = ContinuousClock.now
                    let t = try await Transcriber.shared.transcribeMeetingChunk(chunk)
                    longest = max(longest, ContinuousClock.now - chunkStart)
                    let offset = Duration.milliseconds(range.lowerBound)
                    words = ChunkStitch.append(t.words.map { Transcriber.Word(text: $0.text, confidence: $0.confidence, start: $0.start + offset, end: $0.end + offset) },
                                               after: words, overlapMs: Fixed.meetingChunkOverlapSeconds * 1000)
                }
                let chunkedTime = ContinuousClock.now - started
                let chunkedText = words.map(\.text).joined(separator: " ")
                let diff = chunkedText.split(separator: " ").map(String.init).difference(from: whole.text.split(separator: " ").map(String.init))
                DebugLog.write("Meeting probe transcribe: \(counted(cuts.count, "chunk")) in \(chunkedTime), longest chunk \(longest), \(counted(words.count, "word")), \(diff.insertions.count + diff.removals.count) word edits against whole, resident \(residentMB()) MB")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try whole.text.write(to: directory.appendingPathComponent("whole.txt"), atomically: true, encoding: .utf8)
                try chunkedText.write(to: directory.appendingPathComponent("chunked.txt"), atomically: true, encoding: .utf8)
            } catch {
                DebugLog.write("Meeting probe transcribe: \(error.localizedDescription)")
            }
        }
    }

    nonisolated private static func residentMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size >> 20) : 0
    }
}
