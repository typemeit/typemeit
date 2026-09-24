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
///     -diarizeFile <path>                   the file through FluidAudio's defaults and S3's starting values (S3)
///     -voicePrintProbe                      the user's print from kept dictations against every recorded meeting's speakers (S3)
///     -meetingProbeAX <bundle id> [<s>]     the app's web content through the accessibility tree, once and then every second (S4)
///     -importFile <path>                    import a recording as a meeting, as the tab does (7.14)
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
        if let path = value(after: "-diarizeFile") { diarizeFile(URL(fileURLWithPath: path)) }
        if args.contains("-voicePrintProbe") { voicePrintProbe() }
        if let bundle = value(after: "-meetingProbeAX") { probeAccessibility(bundleID: bundle, seconds: value(after: "-meetingProbeAX", 2).flatMap(Int.init) ?? 30) }
        if let id = value(after: "-addSpeakers").flatMap(UUID.init) {
            DebugLog.enabled = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                MeetingCoordinator.shared.transcribeAgain(id)
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

    private static func diarizeFile(_ url: URL) {
        DebugLog.enabled = true
        let base = OfflineDiarizerConfig(segmentationStepRatio: Fixed.meetingDiarizerStepRatio)
        let s3 = Diarizer.configuration
        let s3Loose = OfflineDiarizerConfig(clusteringThreshold: 0.7, segmentationStepRatio: Fixed.meetingDiarizerStepRatio,
                                            segmentationMinDurationOn: 1.0, segmentationMinDurationOff: 0.5)
        Task.detached {
            do {
                for (name, talk, took) in try await Diarizer.shared.compare(url: url, configurations: [("defaults", base), ("s3 0.5", s3), ("s3 0.7", s3Loose)]) {
                    let shares = talk.sorted { $0.value > $1.value }.map { "\($0.value / 1000)s" }.joined(separator: " ")
                    DebugLog.write("Meeting probe diarize \(name): \(counted(talk.count, "speaker")) [\(shares)] in \(took)")
                }
            } catch {
                DebugLog.write("Meeting probe diarize: \(error.localizedDescription)")
            }
        }
    }

    // MARK: S3, the voice print distance test

    /// Builds a centroid from the newest 50 kept dictations of 5 s or more,
    /// then logs the cosine distance to it of the next 50 (the user, held
    /// out) and of every speaker the diarizer finds on every track of every
    /// recorded meeting: on a call the mic track is the user and the far
    /// end is not.
    private static func voicePrintProbe() {
        DebugLog.enabled = true
        Task.detached {
            func pcm(_ url: URL) -> [Float]? {
                guard let file = try? AVAudioFile(forReading: url),
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                      (try? file.read(into: buffer)) != nil, let data = buffer.floatChannelData?[0] else { return nil }
                return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
            }
            func distance(_ a: [Float], _ b: [Float]) -> Float {
                var dot: Float = 0, na: Float = 0, nb: Float = 0
                for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
                return 1 - dot / (na.squareRoot() * nb.squareRoot())
            }
            let rate = Int(AudioCapture.targetFormat.sampleRate)
            let files = ((try? FileManager.default.contentsOfDirectory(at: RecordingArchive.directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            var prints: [[Float]] = []
            var skipped = 0
            for url in files where prints.count < 100 {
                guard let audio = pcm(url), audio.count >= 5 * rate else { continue }
                if let e = try? await Diarizer.shared.embedding(of: audio) { prints.append(e) } else { skipped += 1 }
            }
            guard prints.count >= 20 else { DebugLog.write("Voice print probe: only \(prints.count) usable dictations"); return }
            let enrol = Array(prints.prefix(prints.count / 2)), held = Array(prints.suffix(prints.count - prints.count / 2))
            var centroid = [Float](repeating: 0, count: enrol[0].count)
            for e in enrol { for i in e.indices { centroid[i] += e[i] } }
            let held_ = held.map { distance($0, centroid) }.sorted()
            DebugLog.write("Voice print probe: \(enrol.count) enrolled, \(skipped) clips not one speaker; held-out dictations min \(held_.first!) median \(held_[held_.count / 2]) max \(held_.last!)")

            let meetings = ((try? FileManager.default.contentsOfDirectory(at: MeetingFolder.defaultPublishedRoot, includingPropertiesForKeys: nil)) ?? [])
                .filter { !["probe", ".in-progress"].contains($0.lastPathComponent) }.sorted { $0.lastPathComponent < $1.lastPathComponent }

            // Clip by clip, as a dictation is: every paragraph of 5 s or more
            // on a call, cut from its own track. The user's are the mic's.
            var clips: [(speaker: String, meeting: String, e: [Float])] = []
            for folder in meetings {
                guard let meeting = MeetingFolder.read(folder), meeting.kind == .call else { continue }
                for track in meeting.tracks {
                    guard let file = try? AVAudioFile(forReading: folder.appendingPathComponent(track.file)) else { continue }
                    for p in meeting.paragraphs where p.endMs - p.startMs >= 5000 && (p.speaker == Meeting.Speaker.you) == (track.role == .mic) {
                        let start = AVAudioFramePosition(p.startMs * Meeting.framesPerMs)
                        let count = AVAudioFrameCount(min(p.endMs - p.startMs, 15_000) * Meeting.framesPerMs)
                        file.framePosition = start
                        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count), (try? file.read(into: buffer, frameCount: count)) != nil,
                              let data = buffer.floatChannelData?[0] else { continue }
                        let audio = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
                        if let e = try? await Diarizer.shared.embedding(of: audio) { clips.append((p.speaker, String(folder.lastPathComponent.prefix(15)), e)) }
                    }
                }
            }
            func summary(_ ds: [Float]) -> String {
                let d = ds.sorted()
                return d.isEmpty ? "none" : "n=\(d.count) min \(String(format: "%.2f", d.first!)) median \(String(format: "%.2f", d[d.count / 2])) max \(String(format: "%.2f", d.last!))"
            }
            let mine = clips.filter { $0.speaker == Meeting.Speaker.you }, theirs = clips.filter { $0.speaker != Meeting.Speaker.you }
            DebugLog.write("Voice print probe clips, dictation print: you \(summary(mine.map { distance($0.e, centroid) })) | others \(summary(theirs.map { distance($0.e, centroid) }))")
            // A print from the user's call audio instead: the first call's mic
            // clips, tested on the other call.
            let meetingNames = Array(Set(clips.map(\.meeting))).sorted()
            if meetingNames.count >= 2 {
                for (train, test) in [(meetingNames[0], meetingNames[1]), (meetingNames[1], meetingNames[0])] {
                    let enrolClips = mine.filter { $0.meeting == train }
                    guard !enrolClips.isEmpty else { continue }
                    var c = [Float](repeating: 0, count: enrolClips[0].e.count)
                    for e in enrolClips { for i in e.e.indices { c[i] += e.e[i] } }
                    DebugLog.write("Voice print probe clips, print from \(train) mic (\(enrolClips.count)) on \(test): you \(summary(mine.filter { $0.meeting == test }.map { distance($0.e, c) })) | others \(summary(theirs.filter { $0.meeting == test }.map { distance($0.e, c) })) | dictations \(summary(held.map { distance($0, c) }))")
                }
            }
            for (speaker, group) in Dictionary(grouping: theirs, by: { "\($0.meeting) \($0.speaker)" }).sorted(by: { $0.key < $1.key }) {
                DebugLog.write("Voice print probe clips: \(speaker) \(summary(group.map { distance($0.e, centroid) }))")
            }

            for folder in meetings {
                for track in ["mic", "others", "room"] {
                    guard let url = ["m4a", "caf"].map({ folder.appendingPathComponent("\(track).\($0)") }).first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { continue }
                    guard let (segments, embeddings) = try? await Diarizer.shared.run(url: url) else { continue }
                    var talk: [String: Int] = [:]
                    for s in segments { talk[s.speaker, default: 0] += s.endMs - s.startMs }
                    let lines = embeddings.map { (id: $0.key, d: distance($0.value, centroid), s: (talk[$0.key] ?? 0) / 1000) }
                        .sorted { $0.s > $1.s }.map { "\($0.id) \($0.s)s d=\(String(format: "%.3f", $0.d))" }
                    DebugLog.write("Voice print probe: \(folder.lastPathComponent) \(track): \(lines.joined(separator: ", "))")
                }
            }
            DebugLog.write("Voice print probe: done")
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
                let meetingNodes = Roster.meetingNodes(pid: app.processIdentifier, target: target)
                let reading = RosterRules.read(meetingNodes, target: target)
                DebugLog.write("Meeting probe names t=\(tick)s: \(meetingNodes.count) nodes in \((ContinuousClock.now - started).milliseconds) ms; roster \(reading.roster), speaking \(reading.speaking.sorted()), \(counted(reading.captions.count, "caption line")), channel \(reading.channel ?? "-")")
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
