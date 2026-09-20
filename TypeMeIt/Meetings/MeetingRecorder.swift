import CoreAudio
import Foundation

/// One meeting being recorded: a `MeetingCapture` feeding one or two
/// `TrackWriter`s, with the silence monitor, the gaps, the dictation spans
/// and the levels the tab shows (docs/meetings.md 7.6). Owned by the
/// coordinator; every callback arrives on the capture's drain queue.
final class MeetingRecorder: @unchecked Sendable, MeetingCaptureSink {
    enum Kind {
        case call(ProcessOwner.Owner, processes: [AudioObjectID])
        case room
    }

    struct Result: Sendable {
        var tracks: [Meeting.Track]
        var peaks: [Meeting.Track.Role: Float]
        var dictations: [Meeting.Dictation]
        var durationMs: Int
        var recordedMs: Int
        var bothSilentMs: Int
        var firstHostTime: UInt64
    }

    let kind: Kind
    let folder: URL
    /// The meeting as written at the start; the coordinator carries it on.
    let meeting: Meeting

    /// True once every track has stayed at the floor for
    /// `Fixed.meetingSilentSeconds`; false when signal returns.
    var onSilenceChanged: (@Sendable (Bool) -> Void)?
    /// Every drain, for the tab's meters.
    var onLevels: (@Sendable (_ mic: Float, _ others: Float?) -> Void)?
    /// The staging volume fell under `Fixed.meetingMinimumFreeBytes`.
    var onDiskFull: (@Sendable () -> Void)?
    var onFailed: (@Sendable (Error) -> Void)?

    private let lock = NSLock()
    private var capture: MeetingCapture?
    private var writers: [(role: Meeting.Track.Role, writer: TrackWriter)] = []
    private var paused = false
    private var pauseStartFrame: Int?
    private var gaps: [Meeting.Span] = []
    private var dictations: [Meeting.Dictation] = []
    private var silent = false
    private var silentSinceFrame: Int?
    private var bothSilentFrames = 0
    private var lastDiskCheck = ContinuousClock.now
    private var stopped = false
    private static let diskCheckInterval: Duration = .seconds(60)

    init(kind: Kind, folder: URL, mic: MeetingCapture.Device) throws {
        self.kind = kind
        self.folder = folder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var excluded = folder
        try? excluded.setResourceValues(values)

        let roles: [Meeting.Track.Role]
        let owner: ProcessOwner.Owner?
        let processes: [AudioObjectID]?
        switch kind {
        case .call(let o, let p): roles = [.mic, .others]; owner = o; processes = p
        case .room: roles = [.room]; owner = nil; processes = nil
        }
        writers = try roles.map { ($0, try TrackWriter(url: folder.appendingPathComponent("\($0.rawValue).caf"))) }
        let speakers: [Meeting.Speaker] = owner == nil
            ? [Meeting.Speaker(id: Meeting.Speaker.room, name: "Room", isYou: false, talkMs: 0)]
            : [Meeting.Speaker(id: Meeting.Speaker.you, name: "You", isYou: true, talkMs: 0), Meeting.Speaker(id: Meeting.Speaker.them, name: "Them", isYou: false, talkMs: 0)]
        meeting = Meeting(
            id: UUID(), kind: owner == nil ? .room : .call, started: Date(), timeZone: TimeZone.current.identifier, ended: nil,
            durationMs: 0, recordedMs: 0, firstHostTime: nil,
            app: owner.map { Meeting.App(bundleId: $0.bundleID, name: $0.name) },
            title: owner?.name ?? "Room", titleSource: .app, published: false,
            tracks: roles.map { Meeting.Track(role: $0, file: "\($0.rawValue).caf", frames: 0) },
            audio: MeetingCapture.audioDescription(mic: mic), echo: .notMeasured, bothSilentMs: 0,
            dictations: [], speakers: speakers,
            transcription: Meeting.Transcription(state: .pending), paragraphs: [])
        try MeetingFolder.write(meeting, to: folder)
        capture = try MeetingCapture(mic: mic, tapProcesses: processes, sink: self)
        DebugLog.write("Meeting recording started: \(meeting.kind.rawValue) \(meeting.title) in \(folder.lastPathComponent)")
    }

    var firstHostTime: UInt64 { capture?.firstHostTime ?? 0 }

    func updateTap(processes: [AudioObjectID]) {
        capture?.updateTap(processes: processes)
    }

    /// The app released the mic: the writers take silence until `resume`.
    func pause() {
        lock.lock()
        guard !paused else { lock.unlock(); return }
        paused = true
        pauseStartFrame = writers.first?.writer.framesWritten ?? 0
        lock.unlock()
        DebugLog.write("Meeting recording paused")
    }

    func resume() {
        lock.lock()
        guard paused else { lock.unlock(); return }
        paused = false
        if let start = pauseStartFrame, let end = writers.first?.writer.framesWritten {
            gaps.append(Meeting.Span(startMs: start / Meeting.framesPerMs, endMs: end / Meeting.framesPerMs))
        }
        pauseStartFrame = nil
        lock.unlock()
        DebugLog.write("Meeting recording resumed")
    }

    /// A dictation ran from `startHostTime` to `endHostTime`; its mic words
    /// are folded out of the transcript.
    func noteDictation(startHostTime: UInt64, endHostTime: UInt64, historyId: UUID) {
        let first = firstHostTime
        guard first > 0 else { return }
        let startMs = Int(MeetingCapture.seconds(fromHostTime: first, to: startHostTime) * 1000)
        let endMs = Int(MeetingCapture.seconds(fromHostTime: first, to: endHostTime) * 1000)
        lock.lock()
        dictations.append(Meeting.Dictation(startMs: startMs, endMs: endMs, historyId: historyId))
        lock.unlock()
    }

    // MARK: Sink

    func capture(_ capture: MeetingCapture, mic: [Float], others: [Float]?) {
        lock.lock()
        let isPaused = paused
        let ws = writers
        lock.unlock()
        for (role, writer) in ws {
            let pcm: [Float] = switch role {
            case .mic, .room: mic
            case .others: others ?? []
            }
            if isPaused { writer.appendSilence(frames: pcm.count) } else { writer.append(pcm) }
        }
        onLevels?(AudioCapture.level(forPeak: AudioCapture.peak(mic)), others.map { AudioCapture.level(forPeak: AudioCapture.peak($0)) })
        checkSilence()
        checkDisk()
    }

    func captureGap(_ capture: MeetingCapture, frames: Int) {
        guard frames > 0 else { return }
        lock.lock()
        let ws = writers
        let start = ws.first?.writer.framesWritten ?? 0
        gaps.append(Meeting.Span(startMs: start / Meeting.framesPerMs, endMs: (start + frames) / Meeting.framesPerMs))
        lock.unlock()
        for (_, writer) in ws { writer.appendSilence(frames: frames) }
        DebugLog.write("Meeting recording gap: \(frames / Meeting.framesPerMs) ms")
    }

    func captureFailed(_ capture: MeetingCapture, error: Error) {
        Log.meetings.error("Meeting capture failed: \(error.localizedDescription)")
        DebugLog.write("Meeting capture failed: \(error.localizedDescription)")
        onFailed?(error)
    }

    /// Every track at the floor for the whole window means the tap is
    /// silent, or everyone is muted; either way the coordinator hears once
    /// when it starts and once when it ends.
    private func checkSilence() {
        lock.lock()
        let ws = writers
        let window = Fixed.meetingSilentSeconds * Int(AudioCapture.targetFormat.sampleRate)
        let written = ws.first?.writer.framesWritten ?? 0
        let allAtFloor = written >= window && ws.allSatisfy { $0.writer.recentPeak < Fixed.meetingSilenceFloor }
        let changed = allAtFloor != silent
        if changed {
            if allAtFloor { silentSinceFrame = written - window } else if let since = silentSinceFrame { bothSilentFrames += written - since; silentSinceFrame = nil }
            silent = allAtFloor
        }
        lock.unlock()
        if changed {
            DebugLog.write("Meeting tracks \(allAtFloor ? "at the floor for \(Fixed.meetingSilentSeconds) s" : "have signal again")")
            onSilenceChanged?(allAtFloor)
        }
    }

    private func checkDisk() {
        lock.lock()
        guard ContinuousClock.now - lastDiskCheck >= MeetingRecorder.diskCheckInterval else { lock.unlock(); return }
        lastDiskCheck = .now
        lock.unlock()
        guard let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage, free < Fixed.meetingMinimumFreeBytes else { return }
        Log.meetings.error("Staging volume has \(free) bytes free; stopping the meeting")
        onDiskFull?()
    }

    // MARK: Stop

    /// Stops the capture, finishes the writers and reports what was written.
    func stop() -> Result {
        lock.lock()
        let alreadyStopped = stopped
        stopped = true
        let cap = capture
        capture = nil
        if paused, let start = pauseStartFrame, let end = writers.first?.writer.framesWritten {
            gaps.append(Meeting.Span(startMs: start / Meeting.framesPerMs, endMs: end / Meeting.framesPerMs))
            paused = false
        }
        let ws = writers
        lock.unlock()
        cap?.stop()
        // Resampling can leave the tracks a frame or two apart; the longer
        // one sets the length and the others are padded to it.
        let longest = ws.map(\.writer.framesWritten).max() ?? 0
        for (_, writer) in ws where writer.framesWritten < longest { writer.appendSilence(frames: longest - writer.framesWritten) }
        var tracks: [Meeting.Track] = []
        var peaks: [Meeting.Track.Role: Float] = [:]
        for (role, writer) in ws {
            let finished = writer.finish()
            tracks.append(Meeting.Track(role: role, file: "\(role.rawValue).caf", frames: finished.frames, gaps: gaps, peak: finished.peak))
            peaks[role] = finished.peak
        }
        lock.lock()
        if silent, let since = silentSinceFrame { bothSilentFrames += longest - since; silentSinceFrame = nil }
        let silentFrames = bothSilentFrames
        let spans = dictations
        lock.unlock()
        let durationMs = longest / Meeting.framesPerMs
        let gapMs = gaps.reduce(0) { $0 + max(0, $1.endMs - $1.startMs) }
        if !alreadyStopped { DebugLog.write("Meeting recording stopped: \(durationMs) ms, \(counted(gaps.count, "gap")), \(counted(spans.count, "dictation"))") }
        return Result(tracks: tracks, peaks: peaks, dictations: spans, durationMs: durationMs, recordedMs: max(0, durationMs - gapMs),
                      bothSilentMs: silentFrames / Meeting.framesPerMs, firstHostTime: cap?.firstHostTime ?? 0)
    }
}
