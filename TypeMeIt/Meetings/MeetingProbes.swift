import AppKit
import AVFoundation
import CoreAudio
import FluidAudio
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
///     -diarizeFile <path>...                each file through a sweep of clustering settings; segments to probe/diarize-<name>.json (S3)
///     -meetingProbeAX <bundle id> [<s>]     the app's web content through the accessibility tree, once and then every second (S4)
///     -importFile <path>                    import a recording as a meeting, as the tab does (7.14)
///     -summarise <meeting id>...            write each meeting's summary to the log, without saving it
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
        if let i = args.firstIndex(of: "-diarizeFile") {
            diarizeFiles(args[(i + 1)...].prefix { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) })
        }
        if let bundle = value(after: "-meetingProbeAX") { probeAccessibility(bundleID: bundle, seconds: value(after: "-meetingProbeAX", 2).flatMap(Int.init) ?? 30) }
        if let id = value(after: "-addSpeakers").flatMap(UUID.init) {
            DebugLog.enabled = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                MeetingCoordinator.shared.transcribeAgain(id)
            }
        }
        if let i = args.firstIndex(of: "-summarise") {
            let ids = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.compactMap(UUID.init)
            DebugLog.enabled = true
            Task { @MainActor in
                for id in ids {
                    guard let meeting = MeetingStore.shared.meeting(id) else { continue }
                    let started = ContinuousClock.now
                    let summary = await MeetingSummary.summarise(meeting)
                    DebugLog.write("Meeting probe summary \(meeting.title) (\(MeetingSummary.parts(of: meeting, maxWords: Fixed.meetingSummaryChunkWords).count) parts, \(ContinuousClock.now - started)): \(summary ?? "none")")
                }
            }
        }
        if let path = value(after: "-importFile") {
            DebugLog.enabled = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                MeetingCoordinator.shared.importRecordings([URL(fileURLWithPath: path)])
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

    // MARK: S3, diarizer settings

    /// Every file through each clustering threshold and VBx `Fb`, the
    /// segmentation settings as shipped, written raw and after
    /// `SpeakerMerge` so a script can score them against reference labels.
    private static func diarizeFiles(_ urls: [URL]) {
        DebugLog.enabled = true
        var configurations: [(String, OfflineDiarizerConfig)] = []
        for threshold in [0.3, 0.4, 0.5, 0.6, 0.7] {
            for fb in [0.8, 0.4] {
                configurations.append(("t\(threshold) fb\(fb)", OfflineDiarizerConfig(
                    clusteringThreshold: threshold, Fb: fb, segmentationStepRatio: Fixed.meetingDiarizerStepRatio,
                    segmentationMinDurationOn: Fixed.meetingDiarizerMinOnSeconds, segmentationMinDurationOff: Fixed.meetingDiarizerMinOffSeconds)))
            }
        }
        Task.detached {
            for url in urls {
                do {
                    var out: [String: [String: [SpeakerSegment]]] = [:]
                    for run in try await Diarizer.shared.compare(url: url, configurations: configurations) {
                        let merged = SpeakerMerge.absorbingShort(run.segments, embeddings: run.embeddings, minimumMs: Fixed.meetingMinimumSpeakerSeconds * 1000)
                        out[run.name] = ["raw": run.segments, "merged": merged]
                        DebugLog.write("Meeting probe diarize \(url.lastPathComponent) \(run.name): \(counted(Set(run.segments.map(\.speaker)).count, "speaker")), merged \(Set(merged.map(\.speaker)).count), in \(run.took)")
                    }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let name = url.deletingPathExtension().lastPathComponent + "-" + url.deletingLastPathComponent().lastPathComponent.prefix(15).replacingOccurrences(of: " ", with: "_")
                    try JSONEncoder().encode(out).write(to: directory.appendingPathComponent("diarize-\(name).json"))
                } catch {
                    DebugLog.write("Meeting probe diarize: \(error.localizedDescription)")
                }
            }
            DebugLog.write("Meeting probe diarize: done")
        }
    }

    // MARK: S4, the accessibility tree

    /// Sets the app's activation attribute (Electron's `AXManualAccessibility`,
    /// Chromium's `AXEnhancedUserInterface`), waits for the tree to build,
    /// writes every element under each `AXWebArea` to `ax-<bundle>-0.txt`,
    /// then every second logs the lines that appeared or went, and clears
    /// the attribute at the end. What it finds decides 8.6's sources.
    private static func probeAccessibility(bundleID: String, seconds: Int) {
        DebugLog.enabled = true
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.activationPolicy == .regular }) else {
            DebugLog.write("Meeting probe AX: \(bundleID) is not running")
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        let attribute = bundleID == "com.tinyspeck.slackmacgap" ? "AXManualAccessibility" : "AXEnhancedUserInterface"
        let set = AXUIElementSetAttributeValue(root, attribute as CFString, kCFBooleanTrue)
        DebugLog.write("Meeting probe AX: \(attribute) on \(bundleID): \(set == .success ? "set" : "refused (\(set.rawValue))")")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var previous = Set<String>()
            let target: Roster.Target = bundleID == "com.tinyspeck.slackmacgap" ? .slackHuddle : .meet
            for tick in 0...seconds {
                // What the meeting reader itself would see, and what it costs.
                let started = ContinuousClock.now
                let (meetingNodes, code) = Roster.meetingNodes(pid: app.processIdentifier, target: target)
                let reading = RosterRules.read(meetingNodes, target: target)
                DebugLog.write("Meeting probe names t=\(tick)s: \(meetingNodes.count) nodes in \((ContinuousClock.now - started).milliseconds) ms; roster \(reading.roster), speaking \(reading.speaking.sorted()), \(counted(reading.captions.count, "caption line")), channel \(reading.channel ?? "-"), meet code \(code ?? "-")")
                let lines = webAreaLines(root)
                if tick == 0 {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let file = directory.appendingPathComponent("ax-\(bundleID)-0.txt")
                    try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
                    DebugLog.write("Meeting probe AX: \(lines.count) elements under the web areas, written to \(file.path)")
                } else {
                    let now = Set(lines)
                    let added = now.subtracting(previous), gone = previous.subtracting(now)
                    if !added.isEmpty || !gone.isEmpty {
                        DebugLog.write("Meeting probe AX t=\(tick)s:\n" + (added.sorted().map { "  + \($0)" } + gone.sorted().map { "  - \($0)" }).joined(separator: "\n"))
                    }
                }
                previous = Set(lines)
                try? await Task.sleep(for: .seconds(1))
            }
            AXUIElementSetAttributeValue(root, attribute as CFString, kCFBooleanFalse)
            DebugLog.write("Meeting probe AX: \(attribute) cleared")
        }
    }

    /// One line per element under every web area: depth, role, and the
    /// title, description, value and help that carry text.
    private static func webAreaLines(_ root: AXUIElement) -> [String] {
        var lines: [String] = []
        func string(_ element: AXUIElement, _ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let text = value as? String, !text.isEmpty else { return nil }
            return text
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
            return value as? [AXUIElement] ?? []
        }
        func walk(_ element: AXUIElement, depth: Int, inWeb: Bool) {
            guard depth < 60, lines.count < 20_000 else { return }
            let role = string(element, kAXRoleAttribute) ?? "?"
            let web = inWeb || role == "AXWebArea"
            if web {
                let texts = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute, "AXDOMIdentifier", "AXDOMClassList"]
                    .compactMap { a in string(element, a).map { "\(a.replacingOccurrences(of: "AX", with: ""))=\($0.prefix(120))" } }
                lines.append(String(repeating: " ", count: depth) + role + (texts.isEmpty ? "" : " " + texts.joined(separator: " ")))
            }
            for child in children(element) { walk(child, depth: depth + 1, inWeb: web) }
        }
        walk(root, depth: 0, inWeb: false)
        return lines
    }
}
