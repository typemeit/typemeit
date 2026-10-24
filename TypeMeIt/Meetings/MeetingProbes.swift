import AppKit
import AVFoundation
import CoreAudio
import FluidAudio
import Foundation
import SwiftUI

/// The spikes in docs/meetings.md section 6, as launch arguments on the dev
/// app. Each writes to the debug log and to `SupportPaths.meetingsRoot/probe/`,
/// and goes once its pass/fail line in the spec is filled in.
///
///     -meetingProbe                         log every process object on every fire and every second (S1)
///     -meetingProbeCapture <bundle id> <s>  tap an app for <s> seconds beside the mic and log the tracks (S1)
///         … self <s>                        tap this app while it plays a tone, and log the tone's pitch in the far-end track
///         … micClock                        clock the aggregate on the mic, as for a Bluetooth output
///         … micRate <hz>                    run the mic at <hz> for the probe, so the tap's rate differs; restored after
///     -audioCheck                           settings' "check audio" two seconds after launch, to the log only, the clipboard left alone
///     -recordRoom <s>                       record the room for <s> seconds through the whole pipeline (7.1)
///     -transcribeFile <path>                whole-file against chunked on one CAF (S2)
///     -renderAnswerPill <folder>            the answer pill's stages, light and dark, as PNGs in <folder>
///     -listClaudeModels                     the models ClaudeModels reads from the CLI, to the debug log
///     -transcribeDictation <path>           one 16 kHz file through dictation's transcription, text to probe/dictation.txt
///     -addSpeakers <meeting id>             run the pass again on a finished meeting with the diarizer (S3)
///     -transcribeCopies <meeting id>...     the whole pass on a copy of each meeting, in probe/rerun-<time>/, keeping each track's words; the meetings stay as they are
///     -diarizeFile <path>...                each file through a sweep of clustering settings; segments to probe/diarize-<name>.json (S3)
///     -diarizeCounts <path>...              each file left to count its speakers, then told 1…6; segments to probe/counts-<name>.json
///     -meetingProbeAX <bundle id> [<s>]     the app's web content through the accessibility tree, once and then every second (S4)
///     -summarise <meeting id>...            write each meeting's summary to the log, without saving it
///     -dumpMeetingPages <meeting id>...     open each meeting's page in settings and write a window dump (WindowDump)
@MainActor
enum MeetingProbes {
    nonisolated static let directory = SupportPaths.meetingsRoot.appendingPathComponent("probe", isDirectory: true)

    static func runIfAsked() {
        let args = CommandLine.arguments
        func value(after flag: String, _ offset: Int = 1) -> String? {
            guard let i = args.firstIndex(of: flag), i + offset < args.count else { return nil }
            return args[i + offset]
        }
        if args.contains("-meetingProbe") { probeProcesses() }
        if let bundle = value(after: "-meetingProbeCapture"), let seconds = value(after: "-meetingProbeCapture", 2).flatMap(Int.init) {
            probeCapture(bundleID: bundle, seconds: seconds, clockOnMic: args.contains("micClock"), micRate: value(after: "micRate").flatMap(Double.init))
        }
        if args.contains("-audioCheck") {
            Task {
                try? await Task.sleep(for: .seconds(2))
                DebugLog.writeReport(await AudioCheck.report())
            }
        }
        if let seconds = value(after: "-recordRoom").flatMap(Int.init) { recordRoom(seconds: seconds) }
        if let path = value(after: "-transcribeFile") { transcribeFile(URL(fileURLWithPath: path)) }
        if let path = value(after: "-renderAnswerPill") { renderAnswerPill(into: URL(fileURLWithPath: path, isDirectory: true)) }
        if let path = value(after: "-renderPillStack") { renderPillStack(into: URL(fileURLWithPath: path, isDirectory: true)) }
        if args.contains("-listClaudeModels") {
            DebugLog.enabled = true
            Task {
                let models = await ClaudeModels.load()
                DebugLog.write("Claude models: \(models.map { "\($0.value) (\($0.displayName))" }.joined(separator: ", "))")
            }
        }
        if let path = value(after: "-transcribeDictation") { transcribeDictation(URL(fileURLWithPath: path)) }
        if let i = args.firstIndex(of: "-diarizeFile") {
            diarizeFiles(args[(i + 1)...].prefix { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) })
        }
        if let i = args.firstIndex(of: "-diarizeCounts") {
            diarizeFiles(args[(i + 1)...].prefix { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }, configurations: countSweep, output: "counts")
        }
        if let bundle = value(after: "-meetingProbeAX") { probeAccessibility(bundleID: bundle, seconds: value(after: "-meetingProbeAX", 2).flatMap(Int.init) ?? 30) }
        if let id = value(after: "-addSpeakers").flatMap(UUID.init) {
            DebugLog.enabled = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                MeetingCoordinator.shared.transcribeAgain(id)
            }
        }
        if let i = args.firstIndex(of: "-transcribeCopies") {
            let ids = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.compactMap(UUID.init)
            DebugLog.enabled = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                DebugLog.write("Meeting probe copies: \(counted(ids.count, "meeting"))")
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
                let root = directory.appendingPathComponent("rerun-\(stamp)", isDirectory: true)
                for id in ids { await transcribeCopy(id, into: root) }
                DebugLog.write("Meeting probe copies: done, in \(root.lastPathComponent)")
            }
        }
        if let i = args.firstIndex(of: "-dumpMeetingPages") {
            let ids = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.compactMap(UUID.init)
            DebugLog.enabled = true
            Task { @MainActor in
                for id in ids {
                    try? await Task.sleep(for: .seconds(3))
                    AppState.shared.settingsTab = .meetings
                    AppState.shared.revealMeeting = id
                    NotificationCenter.default.post(name: MenuBarLabel.openSettings, object: nil)
                    try? await Task.sleep(for: .seconds(4))
                    DebugLog.write("Meeting probe page: \(id)")
                    WindowDump.write()
                }
            }
        }
        if let i = args.firstIndex(of: "-summarise") {
            let ids = args[(i + 1)...].prefix { !$0.hasPrefix("-") }.compactMap(UUID.init)
            DebugLog.enabled = true
            Task { @MainActor in
                for id in ids {
                    guard var meeting = MeetingStore.shared.meeting(id) else { continue }
                    let started = ContinuousClock.now
                    meeting.summary = await MeetingSummary.summarise(meeting.turns)
                    let title = await MeetingSummary.title(summary: meeting.summary, turns: meeting.turns)
                    DebugLog.write("Meeting probe summary \(meeting.title) → \(title ?? "no title") (\(MeetingSummary.parts(of: meeting.turns, maxWords: MeetingSummary.chunkWords).count) parts, \(ContinuousClock.now - started)): \(meeting.summary ?? "none")")
                }
            }
        }
    }

    // MARK: The whole pass on a copy

    /// A finished meeting's folder copied under `root` and transcribed there
    /// from the first chunk, saved only to the copy.
    private static func transcribeCopy(_ id: UUID, into root: URL) async {
        guard var meeting = MeetingStore.shared.meeting(id), let folder = MeetingStore.shared.folder(for: id) else {
            DebugLog.write("Meeting probe copy: no meeting \(id)")
            return
        }
        let copy = root.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: folder, to: copy)
        } catch {
            DebugLog.write("Meeting probe copy: \(error.localizedDescription)")
            return
        }
        meeting.transcription.done = [:]
        meeting.paragraphs = []
        meeting.summary = nil
        // Each save follows a chunk, when the track's words file holds every
        // word so far; kept under another name, since the pass deletes the
        // file at the end, for trying the echo and merge steps against it.
        let roles = meeting.tracks.map(\.role.rawValue)
        let result = await MeetingTranscriber.run(meeting, folder: copy, save: { _ in
            for role in roles {
                guard let words = try? Data(contentsOf: copy.appendingPathComponent("words-\(role).json")) else { continue }
                try? words.write(to: copy.appendingPathComponent("kept-words-\(role).json"), options: .atomic)
            }
        }) { _ in }
        do {
            try MeetingFolder.write(result, to: copy)
        } catch {
            DebugLog.write("Meeting probe copy: \(error.localizedDescription)")
        }
        DebugLog.write("Meeting probe copy: \(folder.lastPathComponent), \(counted(result.paragraphs.count, "paragraph")), \(result.transcription.state)")
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
        /// The far end, for the pitch of the probe's tone as the capture delivered it.
        private(set) var farEnd = ToneMeter()
        init(mic: TrackWriter, others: TrackWriter?) { self.mic = mic; self.others = others }

        func capture(_ capture: MeetingCapture, mic: [Float], others: [Float]?) {
            self.mic.append(mic)
            if let others {
                self.others?.append(others)
                farEnd.add(others)
            }
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
    private static var probeTone: AVAudioEngine?

    private static func probeCapture(bundleID: String, seconds: Int, clockOnMic: Bool, micRate: Double?) {
        DebugLog.enabled = true
        let objectIDs: [AudioObjectID]
        let name: String
        if bundleID == "self" {
            guard let object = AudioProcesses.objectID(forPID: ProcessInfo.processInfo.processIdentifier) else {
                DebugLog.write("Meeting probe capture: no process object for this app")
                return
            }
            do { probeTone = try AudioCheck.playTone() } catch {
                DebugLog.write("Meeting probe capture: tone not started: \(error.localizedDescription)")
                return
            }
            objectIDs = [object]
            name = "this app"
        } else {
            let holders = MeetingWatch.group(AudioProcesses.snapshot(), apps: ProcessOwner.runningApps())
            guard let holder = holders.first(where: { $0.owner.bundleID == bundleID }) ?? holders.first(where: { $0.owner.bundleID.hasPrefix(bundleID) }) else {
                DebugLog.write("Meeting probe capture: no process object with audio for \(bundleID); holders: \(MeetingWatch.describe(holders))")
                return
            }
            objectIDs = holder.objectIDs
            name = holder.owner.name
        }
        guard let mic = MeetingCapture.microphone(preferredUID: Settings.shared.microphoneUID), let micID = AudioCapture.deviceID(forUID: mic.uid) else { return }
        let originalMicRate = MeetingCapture.property(micID, kAudioDevicePropertyNominalSampleRate, Double(0))
        if let micRate { setNominalRate(micID, micRate) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sink = ProbeSink(mic: try TrackWriter(url: directory.appendingPathComponent("mic.caf")),
                                 others: try TrackWriter(url: directory.appendingPathComponent("others.caf")))
            let capture = try MeetingCapture(mic: mic, tapProcesses: objectIDs, sink: sink, clockOnMic: clockOnMic)
            probeCapture = capture
            DebugLog.write("Meeting probe capture: tapping \(name) (\(objectIDs)) for \(seconds) s; tap format \(capture.tapFormat.map { "\($0.mSampleRate) Hz \($0.mChannelsPerFrame) ch" } ?? "-"), aggregate \(capture.micFormat.mSampleRate) Hz")
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                DebugLog.write("Meeting probe capture: first host time \(capture.firstHostTime)")
                capture.stop()
                probeTone?.stop()
                probeTone = nil
                if micRate != nil, let originalMicRate { setNominalRate(micID, originalMicRate) }
                let m = sink.mic.finish()
                let o = sink.others?.finish()
                DebugLog.write("Meeting probe capture: mic \(m.frames) frames peak \(m.peak); others \(o?.frames ?? 0) frames peak \(o?.peak ?? 0); files in \(directory.path)")
                if bundleID == "self", let pitch = sink.farEnd.pitch(rate: AudioCapture.targetFormat.sampleRate) {
                    DebugLog.write("Meeting probe capture: tone played at \(AudioCheck.toneHz) Hz, others track carries \(String(format: "%.1f", pitch)) Hz")
                }
                probeCapture = nil
            }
        } catch {
            if micRate != nil, let originalMicRate { setNominalRate(micID, originalMicRate) }
            probeTone?.stop()
            probeTone = nil
            DebugLog.write("Meeting probe capture: \(error.localizedDescription)")
        }
    }

    private static func setNominalRate(_ device: AudioDeviceID, _ rate: Double) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = rate
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value)
        DebugLog.write("Meeting probe capture: mic rate set to \(rate) Hz (\(status))")
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

    // MARK: The answer pill

    /// Meeting pills are kept out of screen capture, so the answer pill is
    /// drawn in an offscreen window instead, each stage on the desk colour.
    private static func renderAnswerPill(into folder: URL) {
        let question = "So before we go any further, how many calls did we have last week across all the tracked numbers, and how does that compare with the same week last year, and did the new forwarding rules change anything?"
        let answer = ClaudeRun.Answer(
            text: "**1,284 inbound calls** last week (Monday 29 September to Sunday 5 October), up 6% on the week before.\n\nCounted from the calls table: inbound calls that connected, grouped by day. Tuesday was the busiest day with 241.",
            seconds: 23, costUSD: 0.08, failed: false)
        let failed = ClaudeRun.Answer(text: "Log in to Claude Code: run claude in a terminal and type /login.", seconds: 3, costUSD: nil, failed: true)
        let stages: [(String, AnswerPill.Stage, Bool)] = [
            ("offered", .offered, true), ("asking", .asking, true), ("answer", .answered(answer), true),
            ("folded", .answered(answer), false), ("failed", .answered(failed), true),
        ]
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, stage, expanded) in stages {
                for dark in [false, true] {
                    // Through PillView, as the overlay shows it.
                    let model = OverlayModel()
                    model.answerExpanded = expanded
                    model.askOpens = true
                    model.state = switch stage {
                    case .offered, .queued: .meetingQuestion(text: question)
                    case .asking: .meetingAsking(text: question)
                    case .answered(let answer): .meetingAnswer(text: question, answer: answer)
                    }
                    let view = PillView(model: model)
                        .padding(40)
                        .background(dark ? Color(white: 0.086) : Color(white: 0.925))
                        .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.orderFrontRegardless()
                    try? await Task.sleep(for: .milliseconds(400))
                    host.setFrameSize(host.fittingSize)
                    window.setContentSize(host.fittingSize)
                    try? await Task.sleep(for: .milliseconds(400))
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                    }
                    window.orderOut(nil)
                }
            }
            DebugLog.write("Answer pill rendered to \(folder.path)")
            NSApp.terminate(nil)
        }
    }

    /// Answer pills stacked as several questions would stand: an answer
    /// folded, one being answered and one queued behind it; and a new offer
    /// over one being answered. Drawn offscreen like `renderAnswerPill`.
    private static func renderPillStack(into folder: URL) {
        let answer = ClaudeRun.Answer(text: "**1,284 inbound calls** last week, up 6% on the week before.", seconds: 23, costUSD: 0.08, failed: false)
        let stacks: [(String, [(String, AnswerPill.Stage, Bool)])] = [
            ("queue", [("How many calls came in last week?", .answered(answer), false),
                       ("Which table has the inquiries?", .asking, true),
                       ("What changed in the last release?", .queued, true)]),
            ("offer", [("Which table has the inquiries?", .asking, true),
                       ("Is the export done yet?", .offered, true)]),
        ]
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (name, pills) in stacks {
                for dark in [false, true] {
                    let view = VStack(spacing: 8) {
                        ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                            let model = OverlayModel()
                            let _ = { model.answerExpanded = pill.2; model.askOpens = true }()
                            AnswerPill(model: model, question: pill.0, stage: pill.1)
                        }
                    }
                    .padding(40)
                    .background(dark ? Color(white: 0.086) : Color(white: 0.925))
                    .environment(\.colorScheme, dark ? .dark : .light)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 600, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    window.orderFrontRegardless()
                    try? await Task.sleep(for: .milliseconds(400))
                    host.setFrameSize(host.fittingSize)
                    window.setContentSize(host.fittingSize)
                    try? await Task.sleep(for: .milliseconds(400))
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
                    }
                    window.orderOut(nil)
                }
            }
            DebugLog.write("Pill stack rendered to \(folder.path)")
            NSApp.terminate(nil)
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
                let peaks = ChunkCutter.peaks(of: pcm, frameSamples: peakFrames)
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

    /// A long recording as one dictation: on 30 September a 16-minute
    /// dictation crashed the app in one run of the model it used then.
    private static func transcribeDictation(_ url: URL) {
        DebugLog.enabled = true
        Task.detached {
            do {
                let file = try AVAudioFile(forReading: url)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return }
                try file.read(into: buffer)
                let pcm = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                let started = ContinuousClock.now
                let transcript = try await Transcriber.shared.transcribeScored(pcm)
                DebugLog.write("Meeting probe dictation: \(pcm.count / Int(AudioCapture.targetFormat.sampleRate)) s in \(ContinuousClock.now - started), \(counted(transcript.words.count, "word")), resident \(residentMB()) MB")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try transcript.text.write(to: directory.appendingPathComponent("dictation.txt"), atomically: true, encoding: .utf8)
            } catch {
                DebugLog.write("Meeting probe dictation: \(error.localizedDescription)")
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
    private static var thresholdSweep: [(String, OfflineDiarizerConfig)] {
        var configurations: [(String, OfflineDiarizerConfig)] = []
        for threshold in [0.3, 0.4, 0.5, 0.6, 0.7] {
            for fb in [0.8, 0.4] {
                configurations.append(("t\(threshold) fb\(fb)", OfflineDiarizerConfig(
                    clusteringThreshold: threshold, Fb: fb, segmentationStepRatio: Fixed.meetingDiarizerStepRatio,
                    segmentationMinDurationOn: Fixed.meetingDiarizerMinOnSeconds, segmentationMinDurationOff: Fixed.meetingDiarizerMinOffSeconds)))
            }
        }
        return configurations
    }

    /// The shipped settings left to count, then told each count from one to six.
    private static var countSweep: [(String, OfflineDiarizerConfig)] {
        [("auto", Diarizer.configuration)] + (1...6).map { ("exactly \($0)", Diarizer.configuration.withSpeakers(exactly: $0)) }
    }

    private static func diarizeFiles(_ urls: [URL], configurations: [(String, OfflineDiarizerConfig)] = thresholdSweep, output: String = "diarize") {
        DebugLog.enabled = true
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
                    try JSONEncoder().encode(out).write(to: directory.appendingPathComponent("\(output)-\(name).json"))
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
                let (meetingNodes, _, code) = Roster.meetingNodes(pid: app.processIdentifier, target: target)
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
