import AppKit
import CoreAudio
import Foundation
import Observation

/// Owns the meeting machine: feeds it what the watch sees, the clock and
/// the user's clicks, and applies its effects to the pill, the recorder and
/// the transcriber (docs/meetings.md 7.7). The only writer of the machine;
/// the tab's status row and the menu read the live state here, and
/// `MeetingStore` holds the list.
@MainActor
@Observable
final class MeetingCoordinator {
    static let shared = MeetingCoordinator()

    typealias Owner = ProcessOwner.Owner

    struct Live: Equatable {
        let id: UUID
        let kind: Meeting.Kind
        let started: Date
    }

    struct Transcribing: Equatable {
        let id: UUID
        var fraction: Double
    }

    enum SystemAudioTest: Equatable { case notTested, testing, working, silent }

    /// Any holder with input and output, for the menu's item.
    private(set) var detected: Owner?
    private(set) var prompting: Owner?
    private(set) var recording: Live?
    /// Whole minutes the live recording has run. The menu redraws only when
    /// state it reads changes, so the tick advances this for it.
    private(set) var recordingMinutes = 0
    private(set) var levels: (mic: Float, others: Float?) = (0, nil)
    private(set) var transcribing: Transcribing?
    private(set) var systemAudioTest: SystemAudioTest = .notTested
    /// Meetings waiting behind the one being transcribed.
    private(set) var queued: [UUID] = []

    let watch = MeetingWatch()
    @ObservationIgnored private var machine = MeetingMachine()
    @ObservationIgnored private var tick: Timer?
    @ObservationIgnored private var recorder: MeetingRecorder?
    /// Reads names off the meeting's window while a call records (8.6).
    @ObservationIgnored private var roster: Roster?
    /// The capture running since the current candidate formed, and what it
    /// has held so far (D20). Nothing of it reaches a file before `record`.
    @ObservationIgnored private var preRoll: (held: PreRoll, capture: MeetingCapture)?
    @ObservationIgnored private var recordingMeeting: Meeting?
    @ObservationIgnored private var recordingOwner: Owner?
    @ObservationIgnored private var tapObjects: [AudioObjectID] = []
    @ObservationIgnored private var silenceDeadline: Task<Void, Never>?
    @ObservationIgnored private var shownSystemAudioOff = false
    @ObservationIgnored private var stoppedForDisk = false
    @ObservationIgnored private var transcribeQueue: [Meeting] = []
    @ObservationIgnored private var transcribeTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var dictationStart: UInt64?
    @ObservationIgnored private var started = false

    private var overlay: OverlayPanel { Pipeline.shared.overlay }
    private var store: MeetingStore { MeetingStore.shared }
    private var settings: Settings { Settings.shared }

    var isIdle: Bool { recording == nil && transcribing == nil && machine.state == .idle }

    /// Meetings whose files are being written: recording, transcribing or waiting to be.
    var liveIDs: Set<UUID> {
        var ids = Set(queued)
        if let recording { ids.insert(recording.id) }
        if let transcribing { ids.insert(transcribing.id) }
        return ids
    }

    private init() {}

    /// From `Pipeline.start()`: the watch, the tick, sleep, launch recovery
    /// and the model install.
    func start() {
        guard !started else { return }
        started = true
        wirePill()
        watch.onChange = { [weak self] holders in self?.holders(holders) }
        watch.start()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in self.ticked() }
        }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.send(.willSleep) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in self.send(.didWake) }
        }
        for meeting in store.recoverAtLaunch() { enqueue(meeting) }
        store.republishPending()
        observeModel()
    }

    /// Meetings that waited for the speech model go when it lands.
    private func observeModel() {
        withObservationTracking {
            _ = ModelStore.shared.state
        } onChange: {
            Task { @MainActor in
                if ModelStore.shared.state == .installed {
                    for meeting in self.store.pendingForModel where !self.transcribeQueue.contains(where: { $0.id == meeting.id }) && self.transcribing?.id != meeting.id {
                        self.enqueue(meeting)
                    }
                }
                self.observeModel()
            }
        }
    }

    private func wirePill() {
        let model = overlay.model
        model.onRecordMeeting = { [weak self] in self?.recordFromPrompt() }
        model.onDeclineMeeting = { [weak self] in self?.decline() }
        model.onStopMeeting = { [weak self] in self?.dismissToast(); self?.stopMeeting() }
        model.onShowMeeting = { [weak self] id in self?.dismissToast(); self?.showTab(id) }
        model.onTranscribeMeeting = { [weak self] id, now in self?.answerTranscribe(id, now: now) }
        model.onOpenSystemAudio = { [weak self] in self?.dismissToast(); NSWorkspace.shared.open(SecureInput.systemAudioSettingsURL) }
        model.onDismissMeeting = { [weak self] in self?.dismissToast() }
    }

    // MARK: The machine

    private func send(_ event: MeetingMachine.Event) {
        let before = machine.state
        let effects = machine.handle(event, now: .now, rules: .fixed)
        if machine.state != before || !effects.isEmpty {
            DebugLog.write("Meeting machine: \(MeetingCoordinator.describe(event)) → \(MeetingCoordinator.describe(machine.state))\(effects.isEmpty ? "" : " · \(effects.map(MeetingCoordinator.describe).joined(separator: ", "))")")
        }
        for effect in effects { apply(effect) }
        prompting = { if case .prompting(let owner, _) = machine.state { return owner } else { return nil } }()
    }

    private func holders(_ holders: [MeetingWatch.Holder]) {
        detected = holders.first { $0.input && $0.output }?.owner ?? holders.first { $0.input }?.owner
        send(.holders(holders))
        // A helper that restarted mid-call is a new process object: retarget the tap.
        if let owner = recordingOwner, let recorder {
            let objects = holders.first { $0.owner == owner }?.objectIDs ?? []
            if !objects.isEmpty, objects != tapObjects {
                tapObjects = objects
                recorder.updateTap(processes: objects)
            }
        }
    }

    private func ticked() {
        send(.tick(.now))
        if let live = recording {
            let minutes = Int(Date().timeIntervalSince(live.started)) / 60
            if minutes != recordingMinutes { recordingMinutes = minutes }
        }
        if store.meetings.contains(where: { $0.isDone && !$0.published }) { store.republishPending() }
    }

    private func apply(_ effect: MeetingMachine.Effect) {
        switch effect {
        case .beginPreRoll(let owner):
            beginPreRoll(owner)
        case .discardPreRoll:
            discardPreRoll()
        case .showPrompt(let owner):
            guard settings.meetingAsk else { return }
            overlay.showMeeting(.meetingPrompt(app: owner))
        case .hidePrompt:
            if case .meetingPrompt = overlay.model.state { overlay.hideMeeting(overlay.model.state) }
            if case .meetingPrompt? = overlay.model.pendingMeeting { overlay.model.pendingMeeting = nil }
        case .showResumed(let owner):
            toast(.meetingResumed(app: owner))
        case .startRecording(let owner):
            startRecording(owner)
        case .pauseRecording:
            recorder?.pause()
        case .resumeRecording:
            recorder?.resume()
        case .stopRecording:
            stopRecording()
        case .finished(let keep):
            finished(keep: keep)
        }
    }

    // MARK: Pre-roll (D20)

    /// Captures the candidate's call into memory. Soft on failure: without
    /// it the meeting simply starts at the click.
    private func beginPreRoll(_ owner: Owner) {
        discardPreRoll()
        guard settings.meetingPreRoll, settings.meetingAsk else { return }
        let objects = watch.holders.first { $0.owner == owner }?.objectIDs ?? []
        guard !objects.isEmpty, let mic = MeetingCapture.microphone(preferredUID: settings.microphoneUID) else { return }
        let held = PreRoll(owner: owner, seconds: Fixed.meetingPreRollSeconds, tap: true)
        do {
            preRoll = (held, try MeetingCapture(mic: mic, tapProcesses: objects, sink: held))
            DebugLog.write("Meeting pre-roll started for \(owner.name)")
        } catch {
            Log.meetings.notice("Pre-roll not started: \(error.localizedDescription)")
        }
    }

    /// Zeroes and frees the held audio and stops the capture.
    private func discardPreRoll() {
        guard let preRoll else { return }
        self.preRoll = nil
        preRoll.capture.stop()
        preRoll.held.discard()
        DebugLog.write("Meeting pre-roll discarded")
    }

    // MARK: Recording

    private func startRecording(_ owner: Owner?) {
        let id = UUID()
        let kind: MeetingRecorder.Kind
        if let owner {
            let objects = watch.holders.first { $0.owner == owner }?.objectIDs ?? []
            tapObjects = objects
            kind = .call(owner, processes: objects)
        } else {
            kind = .room
        }
        guard let mic = MeetingCapture.microphone(preferredUID: settings.microphoneUID, room: owner == nil) else {
            Log.meetings.error("No microphone to record the meeting with")
            abandonRecording()
            return
        }
        // The pre-roll's capture carries on into the recording when it is
        // this call's; any other is thrown away.
        var handOver: (capture: MeetingCapture, held: PreRoll)?
        if let preRoll, let owner, preRoll.held.owner == owner {
            handOver = (preRoll.capture, preRoll.held)
            self.preRoll = nil
        } else {
            discardPreRoll()
        }
        do {
            let recorder = try MeetingRecorder(id: id, kind: kind, folder: MeetingFolder.staged(id), mic: handOver?.capture.mic ?? mic, preRoll: handOver)
            recorder.onLevels = { [weak self] mic, others in Task { @MainActor in self?.levels = (mic, others) } }
            recorder.onSilenceChanged = { [weak self] silent in Task { @MainActor in self?.silenceChanged(silent) } }
            recorder.onDiskFull = { [weak self] in Task { @MainActor in self?.stoppedForDisk = true; self?.send(.stop) } }
            recorder.onFailed = { [weak self] _ in Task { @MainActor in self?.send(.stop) } }
            self.recorder = recorder
            // Names come from the call's own window whenever a build can read
            // other apps; a sandboxed one cannot (docs/meetings.md 8.6).
            if let owner, Sandbox.readsOtherApps {
                // Meeting time from the recording's own clock, so names line up with words.
                roster = Roster(owner: owner) { [weak recorder] in
                    guard let first = recorder?.firstHostTime, first > 0 else { return nil }
                    return Int(MeetingCapture.seconds(fromHostTime: first, to: mach_absolute_time()) * 1000)
                }
                roster?.start()
            }
            recordingMeeting = recorder.meeting
            recordingOwner = owner
            shownSystemAudioOff = false
            stoppedForDisk = false
            store.adopt(recorder.meeting, folder: recorder.folder)
            recording = Live(id: id, kind: recorder.meeting.kind, started: recorder.meeting.started)
            recordingMinutes = 0
            AppState.shared.meeting = true
        } catch {
            Log.meetings.error("Could not start the meeting recorder: \(error.localizedDescription)")
            DebugLog.write("Meeting recorder failed to start: \(error.localizedDescription)")
            handOver?.capture.stop()
            handOver?.held.discard()
            abandonRecording()
        }
    }

    /// The recorder never started: walk the machine back to idle.
    private func abandonRecording() {
        send(.stop)
        send(.recorderEnded(recordedMs: 0))
    }

    private func stopRecording() {
        silenceDeadline?.cancel()
        silenceDeadline = nil
        lastNames = roster?.finish()
        roster = nil
        guard let recorder else { send(.recorderEnded(recordedMs: 0)); return }
        self.recorder = nil
        Task.detached { [recorder] in
            let result = recorder.stop()
            await MainActor.run { self.recorderEnded(result) }
        }
    }

    private var lastResult: MeetingRecorder.Result?
    private var lastNames: MeetingNames?

    private func recorderEnded(_ result: MeetingRecorder.Result) {
        lastResult = result
        levels = (0, nil)
        send(.recorderEnded(recordedMs: result.recordedMs))
    }

    private func finished(keep: Bool) {
        defer {
            recording = nil
            recordingMeeting = nil
            recordingOwner = nil
            tapObjects = []
            lastResult = nil
            AppState.shared.meeting = false
        }
        guard var meeting = recordingMeeting else { return }
        let folder = MeetingFolder.staged(meeting.id)
        guard keep, let result = lastResult else {
            DebugLog.write("Meeting dropped: \(lastResult?.recordedMs ?? 0) ms recorded")
            try? FileManager.default.removeItem(at: folder)
            store.drop(meeting.id)
            return
        }
        meeting.ended = Date()
        meeting.durationMs = result.durationMs
        meeting.recordedMs = result.recordedMs
        meeting.tracks = result.tracks
        meeting.dictations = result.dictations
        meeting.bothSilentMs = result.bothSilentMs
        meeting.firstHostTime = result.firstHostTime
        meeting.names = lastNames
        lastNames = nil
        // A rejoin of a call recorded minutes ago joins that meeting when it
        // reaches the queue, instead of standing as a second one.
        if let earlier = MeetingMerge.previous(of: meeting, among: store.meetings, window: TimeInterval(Fixed.meetingRejoinMergeMinutes * 60)) {
            meeting.continues = earlier.id
            DebugLog.write("Meeting \(meeting.id) is a rejoin of \(earlier.id); joining them")
        }
        store.save(meeting)
        if stoppedForDisk { toast(.meetingDiskFull(id: meeting.id)) }
        if settings.meetingAskBeforeTranscribing, !stoppedForDisk { askBeforeTranscribing(meeting.id) } else { enqueue(meeting) }
    }

    private func silenceChanged(_ silent: Bool) {
        silenceDeadline?.cancel()
        silenceDeadline = nil
        guard silent else { return }
        if recording?.kind == .call, !shownSystemAudioOff {
            shownSystemAudioOff = true
            toast(.meetingSystemAudioOff)
        }
        let remaining = Fixed.meetingBothSilentEndSeconds - Fixed.meetingSilentSeconds
        silenceDeadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.send(.bothSilent)
        }
    }

    // MARK: The user

    /// The pill's record button.
    func recordFromPrompt() {
        guard let owner = prompting else { return }
        send(.record(owner))
    }

    /// The menu's Record This Meeting: the owner detected at click time.
    func recordDetected() {
        guard let owner = detected else { return }
        send(.record(owner))
    }

    func decline() { send(.decline) }

    func stopMeeting() { send(.stop) }

    func recordRoom() { send(.room) }

    private func showTab(_ id: UUID?) {
        AppState.shared.settingsTab = .meetings
        AppState.shared.revealMeeting = id
        NotificationCenter.default.post(name: MenuBarLabel.openSettings, object: nil)
    }

    // MARK: Dictation

    /// `Pipeline` reports the host time it opened and closed its own
    /// microphone, so the dictation's words are folded out of the meeting.
    func dictationBegan(hostTime: UInt64) {
        dictationStart = hostTime
    }

    func dictationEnded(hostTime: UInt64, historyId: UUID) {
        guard let start = dictationStart else { return }
        dictationStart = nil
        recorder?.noteDictation(startHostTime: start, endHostTime: hostTime, historyId: historyId)
    }

    // MARK: Quit

    /// Stops the meeting and waits, bounded, for the writers, so a quit
    /// mid-meeting keeps what was recorded and transcribes it on relaunch.
    func stopForQuit() {
        discardPreRoll()
        let names = roster?.finish()
        roster = nil
        guard let recorder, let meeting = recordingMeeting else { return }
        self.recorder = nil
        let done = DispatchSemaphore(value: 0)
        let box = ResultBox()
        Thread.detachNewThread {
            box.result = recorder.stop()
            done.signal()
        }
        _ = done.wait(timeout: .now() + .seconds(Fixed.meetingQuitWaitSeconds))
        var finished = meeting
        if let result = box.result {
            finished.ended = Date()
            finished.durationMs = result.durationMs
            finished.recordedMs = result.recordedMs
            finished.tracks = result.tracks
            finished.dictations = result.dictations
            finished.bothSilentMs = result.bothSilentMs
            finished.firstHostTime = result.firstHostTime
            finished.names = names
        }
        try? MeetingFolder.write(finished, to: MeetingFolder.staged(meeting.id))
        DebugLog.write("Meeting saved for quit: \(finished.durationMs) ms")
    }

    private final class ResultBox: @unchecked Sendable {
        var result: MeetingRecorder.Result?
    }

    // MARK: Transcription

    func enqueue(_ meeting: Meeting) {
        guard transcribing?.id != meeting.id, !transcribeQueue.contains(where: { $0.id == meeting.id }) else { return }
        transcribeQueue.append(meeting)
        queued = transcribeQueue.map(\.id)
        pump()
    }

    /// The row's retry: from step 1, skipping chunks already done.
    func retry(_ id: UUID) {
        guard var meeting = store.meeting(id), meeting.transcription.state == .failed else { return }
        meeting.transcription.state = .pending
        meeting.transcription.error = nil
        store.save(meeting)
        enqueue(meeting)
    }

    /// The whole pass again on a finished meeting's kept audio, from the
    /// first chunk, keeping the title and the speaker names.
    func transcribeAgain(_ id: UUID) {
        guard var meeting = store.meeting(id), meeting.isDone, !meeting.audioFiles.isEmpty, !liveIDs.contains(id) else { return }
        meeting.transcription.state = .pending
        meeting.transcription.error = nil
        meeting.transcription.done = [:]
        meeting.paragraphs = []
        meeting.summary = nil
        // A generated title is generated again from the new words; a typed one stays.
        if meeting.titleSource == .generated {
            meeting.title = meeting.app?.name ?? "Room"
            meeting.titleSource = .app
        }
        store.save(meeting)
        enqueue(meeting)
    }

    /// Meetings whose summary is being written, for the page's placeholder.
    private(set) var summarising: Set<UUID> = []

    /// Writes the summary of a transcribed meeting that has none: one from
    /// before summaries, or one the model declined last time.
    func summarise(_ id: UUID) {
        guard let meeting = store.meeting(id), meeting.isDone, meeting.summary == nil, !meeting.paragraphs.isEmpty,
              !summarising.contains(id), !liveIDs.contains(id), transcribing?.id != id else { return }
        summarising.insert(id)
        Task {
            let summary = await MeetingSummary.summarise(meeting)
            summarising.remove(id)
            guard let summary, var latest = store.meeting(id), latest.summary == nil else { return }
            latest.summary = summary
            store.save(latest)
        }
    }

    private func pump() {
        guard transcribeTask == nil, !transcribeQueue.isEmpty else { return }
        var meeting = transcribeQueue.removeFirst()
        queued = transcribeQueue.map(\.id)
        guard let folder = store.folder(for: meeting.id) else { pump(); return }
        // The queue is serial, so the meeting a rejoin continues has
        // finished its own pass by now.
        if let id = meeting.continues {
            if let earlier = store.meeting(id), let earlierFolder = store.folder(for: id), !liveIDs.contains(id) {
                transcribing = Transcribing(id: id, fraction: 0)
                transcribeTask = Task.detached { [meeting, folder] in
                    let joined = await MeetingCoordinator.join(earlier, in: earlierFolder, meeting, in: folder)
                    var alone = meeting
                    alone.continues = nil
                    let result = await MeetingTranscriber.run(joined ?? alone, folder: joined == nil ? folder : earlierFolder) { fraction in
                        Task { @MainActor in MeetingCoordinator.shared.transcribing?.fraction = fraction }
                    }
                    await MainActor.run { MeetingCoordinator.shared.transcribed(result) }
                }
                return
            }
            meeting.continues = nil
            store.save(meeting)
        }
        transcribing = Transcribing(id: meeting.id, fraction: 0)
        transcribeTask = Task.detached { [meeting, folder] in
            let result = await MeetingTranscriber.run(meeting, folder: folder) { fraction in
                Task { @MainActor in
                    if MeetingCoordinator.shared.transcribing?.id == meeting.id { MeetingCoordinator.shared.transcribing?.fraction = fraction }
                }
            }
            await MainActor.run { MeetingCoordinator.shared.transcribed(result) }
        }
    }

    /// Joins `later` onto `earlier` on disk and in the store, and deletes
    /// `later`. Nil, with `later` left to stand alone, if the audio could
    /// not be joined.
    nonisolated private static func join(_ earlier: Meeting, in earlierFolder: URL, _ later: Meeting, in laterFolder: URL) async -> Meeting? {
        let gap = MeetingMerge.gapMs(earlier, later)
        var joined = MeetingMerge.joined(earlier, later, gapMs: gap)
        do {
            let written = try MeetingMerge.joinAudio(earlier, in: earlierFolder, later, in: laterFolder, gapMs: gap)
            for i in joined.tracks.indices {
                if let w = written[joined.tracks[i].role] { joined.tracks[i].frames = w.frames; joined.tracks[i].peak = w.peak }
            }
            joined.durationMs = (joined.tracks.map(\.frames).max() ?? 0) / Meeting.framesPerMs
        } catch {
            Log.meetings.error("Could not join the rejoined call: \(error.localizedDescription)")
            DebugLog.write("Meeting join failed, keeping it separate: \(error.localizedDescription)")
            return nil
        }
        await MainActor.run {
            MeetingStore.shared.save(joined)
            MeetingStore.shared.drop(later.id)
            try? FileManager.default.removeItem(at: laterFolder)
        }
        DebugLog.write("Meeting joined: \(later.id) onto \(earlier.id) after \(gap) ms, now \(joined.durationMs) ms")
        return joined
    }

    private func transcribed(_ meeting: Meeting) {
        transcribing = nil
        transcribeTask = nil
        switch meeting.transcription.state {
        case .done:
            // The tick may have published it between the run's last save and here.
            if store.meeting(meeting.id)?.published == true {
                store.renameFolderIfNeeded(meeting.id)
                if AppState.shared.visibleTab != .meetings { toast(.meetingSaved(id: meeting.id)) }
            } else if store.publish(meeting.id) {
                if AppState.shared.visibleTab != .meetings { toast(.meetingSaved(id: meeting.id)) }
            } else {
                toast(.meetingFolderUnavailable)
            }
        case .failed:
            toast(.meetingFailed(id: meeting.id))
        case .pending, .running:
            break
        }
        pump()
    }

    // MARK: System audio test

    /// Taps our own process while a cue plays and reports whether signal
    /// arrived: the only check there is for the grant (docs/meetings.md D13).
    func testSystemAudio() {
        guard systemAudioTest != .testing, let mic = MeetingCapture.microphone(preferredUID: settings.microphoneUID),
              let object = AudioProcesses.objectID(forPID: ProcessInfo.processInfo.processIdentifier) else { return }
        systemAudioTest = .testing
        let probe = SystemAudioProbe()
        do {
            let capture = try MeetingCapture(mic: mic, tapProcesses: [object], sink: probe)
            probe.capture = capture
        } catch {
            Log.meetings.error("System audio test could not start: \(error.localizedDescription)")
            systemAudioTest = .silent
            return
        }
        Feedback.play(.stop, volume: 1)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            probe.capture?.stop()
            probe.capture = nil
            let heard = probe.peak >= Fixed.meetingSilenceFloor
            DebugLog.write("System audio test: peak \(probe.peak) → \(heard ? "working" : "silent")")
            self?.systemAudioTest = heard ? .working : .silent
        }
    }

    private final class SystemAudioProbe: MeetingCaptureSink, @unchecked Sendable {
        var capture: MeetingCapture?
        private let lock = NSLock()
        private var peakValue: Float = 0
        var peak: Float { lock.lock(); defer { lock.unlock() }; return peakValue }
        func capture(_ capture: MeetingCapture, mic: [Float], others: [Float]?) {
            guard let others else { return }
            let p = AudioCapture.peak(others)
            lock.lock(); peakValue = max(peakValue, p); lock.unlock()
        }
        func captureGap(_ capture: MeetingCapture, frames: Int) {}
        func captureFailed(_ capture: MeetingCapture, error: Error) {}
    }

    // MARK: Toasts

    /// A meeting toast: shown now or parked behind the cloud, and taken
    /// down after `ToastTiming.timeout` unless it stands until answered.
    private func toast(_ state: OverlayModel.State) {
        toastTask?.cancel()
        overlay.showMeeting(state)
        guard !state.isStanding else { return }
        toastTask = Task { [weak self] in
            var remaining = ToastTiming.timeout
            let step: Duration = .milliseconds(100)
            let deadline = ContinuousClock.now + ToastTiming.safetyHide
            while remaining > .zero, ContinuousClock.now < deadline {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled, let self else { return }
                if self.overlay.model.state == state, !self.overlay.model.toastPaused { remaining -= step }
            }
            guard !Task.isCancelled, let self else { return }
            self.overlay.hideMeeting(state)
        }
    }

    /// Settings.meetingAskBeforeTranscribing: the pill offers okay and later
    /// for `Fixed.meetingTranscribeAskSeconds`, counting only while it shows
    /// and is not hovered, and says okay itself when the time is up. A
    /// meeting put off waits, pending, for its transcribe button or the
    /// next launch.
    private func askBeforeTranscribing(_ id: UUID) {
        toastTask?.cancel()
        let state = OverlayModel.State.meetingTranscribeAsk(id: id)
        overlay.showMeeting(state)
        toastTask = Task { [weak self] in
            var remaining = Duration.seconds(Fixed.meetingTranscribeAskSeconds)
            let step: Duration = .milliseconds(100)
            while remaining > .zero {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled, let self else { return }
                if self.overlay.model.state == state, !self.overlay.model.toastPaused { remaining -= step }
            }
            guard !Task.isCancelled, let self else { return }
            self.answerTranscribe(id, now: true)
        }
    }

    private func answerTranscribe(_ id: UUID, now: Bool) {
        toastTask?.cancel()
        overlay.hideMeeting(.meetingTranscribeAsk(id: id))
        guard now, let meeting = store.meeting(id) else {
            DebugLog.write("Meeting transcription later: \(id)")
            return
        }
        enqueue(meeting)
    }

    /// A pending meeting nothing will transcribe until asked: put off from
    /// the pill, and not queued or recording.
    func isWaiting(_ id: UUID) -> Bool {
        guard let meeting = store.meeting(id), meeting.transcription.state == .pending else { return false }
        return !queued.contains(id) && transcribing?.id != id && !liveIDs.contains(id)
    }

    private func dismissToast() {
        toastTask?.cancel()
        let state = overlay.model.state
        guard state.isMeeting else { return }
        overlay.hideMeeting(state)
    }

    // MARK: Logging

    private static func describe(_ event: MeetingMachine.Event) -> String {
        switch event {
        case .holders(let h): "holders(\(MeetingWatch.describe(h)))"
        case .tick: "tick"
        case .record(let o): "record(\(o.name))"
        case .decline: "decline"
        case .stop: "stop"
        case .room: "room"
        case .bothSilent: "bothSilent"
        case .willSleep: "willSleep"
        case .didWake: "didWake"
        case .recorderEnded(let ms): "recorderEnded(\(ms) ms)"
        }
    }

    private static func describe(_ state: MeetingMachine.State) -> String {
        switch state {
        case .idle: "idle"
        case .candidate(let o, _, let both): "candidate(\(o.name)\(both == nil ? "" : ", both"))"
        case .prompting(let o, _): "prompting(\(o.name))"
        case .declined(let o): "declined(\(o.name))"
        case .recording(let o, _): "recording(\(o?.name ?? "room"))"
        case .paused(let o, _, let before): "paused(\(o.name), \(before))"
        case .finishing(let o): "finishing(\(o?.name ?? "room"))"
        }
    }

    private static func describe(_ effect: MeetingMachine.Effect) -> String {
        switch effect {
        case .beginPreRoll(let o): "beginPreRoll(\(o.name))"
        case .discardPreRoll: "discardPreRoll"
        case .showPrompt(let o): "showPrompt(\(o.name))"
        case .hidePrompt: "hidePrompt"
        case .showResumed(let o): "showResumed(\(o.name))"
        case .startRecording(let o): "startRecording(\(o?.name ?? "room"))"
        case .pauseRecording: "pauseRecording"
        case .resumeRecording: "resumeRecording"
        case .stopRecording: "stopRecording"
        case .finished(let keep): "finished(keep: \(keep))"
        }
    }
}
