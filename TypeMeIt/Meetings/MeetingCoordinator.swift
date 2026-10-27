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
        var progress: MeetingTranscriber.Progress
        /// The share of the audio transcribed, all of it once the words are in.
        var fraction: Double {
            if case .transcribing(let f) = progress { f } else { 1 }
        }
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
    /// The hook running now on each meeting whose hooks are running.
    private(set) var runningHooks: [UUID: RunningHook] = [:]
    /// `transcribeSoFar` is running.
    private(set) var transcribingSoFar = false
    /// The question Claude is answering for a meeting, shown on its page.
    private(set) var askingIn: (meeting: UUID, question: Meeting.Question)?
    /// Ask is transcribing or finding its question, before Claude Code
    /// starts on it; until then the question's text names the step.
    private(set) var askPreparing = false
    /// The Claude Code run of each meeting's running hook, for its cancel.
    @ObservationIgnored private var hookRuns: [UUID: ClaudeRun] = [:]
    /// Meetings whose hooks were cancelled: the running one stops and the rest are skipped.
    @ObservationIgnored private var cancelledHooks: Set<UUID> = []

    /// A hook running on a meeting: its run's id, which its output is kept under.
    struct RunningHook: Equatable {
        let runID: UUID
        let name: String
    }
    private(set) var systemAudioTest: SystemAudioTest = .notTested
    /// Meetings waiting behind the one being transcribed.
    private(set) var queued: [UUID] = []
    /// A copy of the live recording is being cut for `transcribeNow`.
    private(set) var snapshotting = false

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
    /// Meetings a recording paused the transcription of, oldest first, to
    /// carry on when it ends. One the user carries on during the call runs.
    @ObservationIgnored private var pausedForRecording: [UUID] = []
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    /// Settings.askClaude: the live transcript that spots questions, and the
    /// Claude Code run answering one.
    @ObservationIgnored private var askRun: ClaudeRun?
    /// The question the pill offered last, for when it was asked, its line
    /// in `QuestionLog`, and the meeting it is kept in.
    @ObservationIgnored private var offered: SpottedQuestion?
    @ObservationIgnored private var offeredLogID: UUID?
    @ObservationIgnored private var offeredMeetingID: UUID?
    /// The dictation that asked the offered question by name.
    @ObservationIgnored private var offeredDictationID: UUID?
    /// What the pill's open shows for the question asked last, through its answer.
    /// The ask was opened: its answer goes to its page, not the pill.
    @ObservationIgnored private var askOpened = false
    @ObservationIgnored private var openTarget: (meeting: UUID?, dictation: UUID?)?
    /// The question Claude Code is answering, as its meeting keeps it.
    @ObservationIgnored private var asking: (question: Meeting.Question, meeting: UUID?, dictation: UUID?)?
    @ObservationIgnored private var dictationStart: UInt64?
    @ObservationIgnored private var started = false
    /// The newest mid-meeting transcript of the live recording, replaced by
    /// the next one and by the finished meeting.
    @ObservationIgnored private var snapshotID: UUID?
    /// Snapshots whose transcription was running when they were replaced;
    /// deleted when it stops.
    @ObservationIgnored private var supersededSnapshots: Set<UUID> = []

    private var overlay: OverlayPanel { Pipeline.shared.overlay }
    private var store: MeetingStore { MeetingStore.shared }
    private var settings: Settings { Settings.shared }

    /// A pre-roll capture is running.
    var holdsPreRoll: Bool { preRoll != nil }
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
        if Settings.shared.meetingLearnVoices { store.learnVoices() }
        observeModel()
        ClaudeCheck.shared.watch()
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
        model.onAskClaude = { [weak self] question in
            self?.logAnswer(.ask)
            self?.askClaude(question)
        }
        model.onDeclineQuestion = { [weak self] _ in
            self?.logAnswer(.no)
            self?.dismissToast()
        }
        model.onCancelAsk = { [weak self] in self?.cancelAsk() }
        model.onRunHooks = { [weak self] id in self?.dismissToast(); self?.runHooks(id) }
        Pipeline.shared.shortcuts.onReturn = { [weak self] in self?.askDictatedOnReturn() ?? false }
        model.onOpenAsk = { [weak self] in self?.openAsk() }
        model.onShowClaudeCheck = { [weak self] in
            self?.dismissToast()
            AppState.shared.revealSection = .assistant
            AppState.shared.settingsTab = .settings
            NotificationCenter.default.post(name: MenuBarLabel.openSettings, object: nil)
        }
        ClaudeCheck.shared.onUnaskedFailure = { [weak self] in
            // An answer or prompt standing in the pill is left alone; settings shows the failure.
            guard let self, !self.overlay.model.state.isStanding else { return }
            self.toast(.claudeCheckFailed)
        }
    }

    /// Opens the dictation that asked the last question, else its meeting,
    /// and takes the pill down; an answer still coming shows only there.
    private func openAsk() {
        askOpened = true
        dismissToast()
        if let dictation = openTarget?.dictation {
            AppState.shared.settingsTab = .history
            AppState.shared.revealDictation = dictation
            NotificationCenter.default.post(name: MenuBarLabel.openSettings, object: nil)
        } else if let meeting = openTarget?.meeting {
            showTab(meeting)
        }
    }

    /// Return asks Claude the question a dictation just asked by name, as the
    /// pill's ask claude does. A question spotted in a meeting leaves Return
    /// alone: the user may be typing in the call's chat.
    private func askDictatedOnReturn() -> Bool {
        guard offeredDictationID != nil, offeredLogID != nil, let question = offered,
              overlay.model.state == .meetingQuestion(text: question.text) else { return false }
        logAnswer(.ask)
        askClaude(question.text)
        return true
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
        // Before the holders, so input coming back for the next call does not
        // resume this one.
        if roster?.showsOtherCall == true { send(.otherCall) }
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
        if roster?.showsOtherCall == true { send(.otherCall) }
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
        guard !objects.isEmpty, let mic = MeetingCapture.microphone(preferredUID: settings.connectedMicrophoneUID()) else { return }
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
        guard let mic = MeetingCapture.microphone(preferredUID: settings.connectedMicrophoneUID(), room: owner == nil) else {
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
            pauseTranscribingForRecording()
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
            // After the meeting just recorded is queued, so its own pass goes first.
            resumeTranscribingAfterRecording()
        }
        let filedWhileLive = [recordingMeeting?.id, snapshotID].compactMap { $0.flatMap(store.meeting)?.folder }.first
        discardSnapshot()
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
        meeting.folder = filedWhileLive ?? Meeting.seriesFolder(for: meeting, among: store.meetings)
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

    /// Transcribes what the live meeting has so far as a meeting of its
    /// own, without stopping the recording. The finished meeting replaces it.
    func transcribeNow() {
        guard let recorder, let live = recording, !snapshotting else { return }
        snapshotting = true
        let id = UUID()
        let folder = MeetingFolder.staged(id)
        let names = roster?.peek()
        Task.detached { [recorder] in
            let result = Result { try recorder.snapshot(id: id, into: folder, names: names) }
            await MainActor.run { MeetingCoordinator.shared.snapshotted(result, liveID: live.id, folder: folder) }
        }
    }

    private func snapshotted(_ result: Result<Meeting, Error>, liveID: UUID, folder: URL) {
        snapshotting = false
        guard case .success(var snapshot) = result else {
            if case .failure(let error) = result { DebugLog.write("Meeting snapshot failed: \(error.localizedDescription)") }
            try? FileManager.default.removeItem(at: folder)
            return
        }
        // The recording stopped while the copy ran: the finished meeting is the transcript.
        guard recorder != nil, recording?.id == liveID else {
            try? FileManager.default.removeItem(at: folder)
            return
        }
        discardSnapshot()
        snapshot.title = "\(snapshot.title), so far"
        snapshotID = snapshot.id
        store.save(snapshot)
        enqueue(snapshot)
    }

    private func discardSnapshot() {
        guard let id = snapshotID else { return }
        snapshotID = nil
        if let i = transcribeQueue.firstIndex(where: { $0.id == id }) {
            transcribeQueue.remove(at: i)
            queued = transcribeQueue.map(\.id)
        }
        if transcribing?.id == id {
            supersededSnapshots.insert(id)
            transcribeTask?.cancel()
        } else {
            store.delete(ids: [id])
        }
    }

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
        // A generated or roster title is made again from the new words; a typed one stays.
        if meeting.titleSource == .generated || meeting.titleSource == .roster {
            meeting.title = meeting.app?.name ?? "Room"
            meeting.titleSource = .app
        }
        store.save(meeting)
        enqueue(meeting)
    }

    /// A call's recording competes with a transcription pass for the GPU,
    /// the Neural Engine and memory, so the pass in hand stops after its
    /// chunk and the queue empties; each waits with its chunks kept.
    private func pauseTranscribingForRecording() {
        let running = transcribing.map { [$0.id] } ?? []
        let paused = running + transcribeQueue.map(\.id)
        guard !paused.isEmpty else { return }
        transcribeQueue.removeAll()
        queued = []
        transcribeTask?.cancel()
        pausedForRecording = paused
        DebugLog.write("Meeting transcription paused for the recording: \(counted(paused.count, "meeting"))")
    }

    private func resumeTranscribingAfterRecording() {
        let paused = pausedForRecording
        pausedForRecording = []
        for id in paused {
            if let meeting = store.meeting(id), meeting.transcription.state == .pending { enqueue(meeting) }
        }
    }

    /// Stops a meeting's transcription: a queued one leaves the queue, and a
    /// running one stops after the chunk in hand and goes back to waiting,
    /// its finished chunks kept for when it is transcribed again.
    func stopTranscribing(_ id: UUID) {
        if let i = transcribeQueue.firstIndex(where: { $0.id == id }) {
            transcribeQueue.remove(at: i)
            queued = transcribeQueue.map(\.id)
        } else if transcribing?.id == id {
            transcribeTask?.cancel()
        }
    }

    /// Meetings whose summary is being written, for the page's placeholder.
    private(set) var summarising: Set<UUID> = []

    /// Writes what a transcribed meeting lacks from the model: a summary,
    /// for one from before summaries or one the model declined last time,
    /// and a title in place of one from the app or the roster, for one
    /// from before generated titles led the ladder (9.2).
    func summarise(_ id: UUID) {
        guard let meeting = store.meeting(id), meeting.isDone, !meeting.paragraphs.isEmpty,
              !summarising.contains(id), !liveIDs.contains(id), transcribing?.id != id else { return }
        let needsSummary = meeting.summary == nil
        let needsTitle = Self.titleIsPlaceholder(meeting)
        guard needsSummary || needsTitle else { return }
        summarising.insert(id)
        Task {
            var written = meeting
            if needsSummary { written.summary = await MeetingSummary.summarise(meeting.turns) }
            let title = needsTitle ? await MeetingSummary.title(summary: written.summary, turns: meeting.turns, callName: meeting.names?.name) : nil
            summarising.remove(id)
            guard var latest = store.meeting(id) else { return }
            var changed = false
            if let summary = written.summary, latest.summary == nil {
                latest.summary = summary
                changed = true
            }
            if let title, Self.titleIsPlaceholder(latest) {
                latest.title = title
                latest.titleSource = .generated
                changed = true
            }
            guard changed else { return }
            store.save(latest)
            store.renameFolderIfNeeded(id)
        }
    }

    /// Meetings a folder is being suggested for, for the page's placeholder.
    private(set) var suggestingFolder: Set<UUID> = []

    /// Asks the model where a meeting with a summary and no folder belongs:
    /// an existing folder or a new one's name (`MeetingFolderPick.suggestion`).
    /// The answer waits on the meeting's page and in the move menu; nothing
    /// is filed until the user takes it.
    func suggestFolder(_ id: UUID) {
        guard let meeting = store.meeting(id), meeting.folder == nil, meeting.folderSuggestion == nil,
              let summary = meeting.summary, !summary.isEmpty, !suggestingFolder.contains(id) else { return }
        let folders = meeting.folderChoices(store.folderCounts.map(\.name), among: store.meetings)
        suggestingFolder.insert(id)
        Task {
            let suggestion = await MeetingFolderPick.suggestion(title: meeting.title, summary: summary, among: folders)
            suggestingFolder.remove(id)
            guard let suggestion else { return }
            store.suggestFolder(suggestion, for: id)
            DebugLog.write("Meeting \(id) has a folder suggestion, from \(counted(folders.count, "folder"))")
        }
    }

    private static func titleIsPlaceholder(_ meeting: Meeting) -> Bool {
        meeting.titleSource == .app || meeting.titleSource == .roster
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
                transcribing = Transcribing(id: id, progress: .transcribing(0))
                transcribeTask = Task.detached { [meeting, folder] in
                    let joined = await MeetingCoordinator.join(earlier, in: earlierFolder, meeting, in: folder)
                    var alone = meeting
                    alone.continues = nil
                    let result = await MeetingTranscriber.run(joined ?? alone, folder: joined == nil ? folder : earlierFolder) { progress in
                        Task { @MainActor in MeetingCoordinator.shared.transcribing?.progress = progress }
                    }
                    await MainActor.run { MeetingCoordinator.shared.transcribed(result) }
                }
                return
            }
            meeting.continues = nil
            store.save(meeting)
        }
        transcribing = Transcribing(id: meeting.id, progress: .transcribing(0))
        transcribeTask = Task.detached { [meeting, folder] in
            let result = await MeetingTranscriber.run(meeting, folder: folder) { progress in
                Task { @MainActor in
                    if MeetingCoordinator.shared.transcribing?.id == meeting.id { MeetingCoordinator.shared.transcribing?.progress = progress }
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
        if supersededSnapshots.remove(meeting.id) != nil {
            store.delete(ids: [meeting.id])
            pump()
            return
        }
        switch meeting.transcription.state {
        case .done where store.meeting(meeting.id)?.paragraphs.allSatisfy({ $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? true:
            // Nothing was said: there is nothing to keep.
            DebugLog.write("Meeting \(meeting.id) had no words; deleted")
            store.delete(ids: [meeting.id])
        case .done:
            // A meeting that ended offers its hooks once; one transcribed so
            // far is still being recorded.
            let saved = OverlayModel.State.meetingSaved(
                id: meeting.id, hooks: hooksReady && meeting.id != snapshotID && (store.meeting(meeting.id)?.hookRuns ?? []).isEmpty)
            // The tick may have published it between the run's last save and here.
            if store.meeting(meeting.id)?.published == true {
                store.renameFolderIfNeeded(meeting.id)
                if AppState.shared.visibleTab != .meetings { toast(saved) }
            } else if store.publish(meeting.id) {
                if AppState.shared.visibleTab != .meetings { toast(saved) }
            } else {
                toast(.meetingFolderUnavailable)
            }
            suggestFolder(meeting.id)
        case .failed:
            toast(.meetingFailed(id: meeting.id))
        case .pending, .running:
            break
        }
        // Nothing left to transcribe, or paused: the speaker models need not stay loaded.
        if transcribeQueue.isEmpty { Task { await Diarizer.shared.unload() } }
        pump()
    }

    // MARK: Hooks

    /// The hooks run hooks runs: switched on, with a prompt.
    private var hooksToRun: [MeetingHook] {
        settings.meetingHooks.filter { $0.on && !$0.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Claude Code can run and there is a hook to run.
    var hooksReady: Bool { ClaudeRun.isAvailable && !hooksToRun.isEmpty }

    /// Runs every hook switched on over the finished meeting, one after
    /// another, keeping each output in the meeting as it lands. Only ever
    /// from a button: the meeting's pill or its page.
    func runHooks(_ id: UUID) {
        guard runningHooks[id] == nil, var source = store.meeting(id), source.isDone else { return }
        let hooks = hooksToRun
        guard let first = hooks.first else { return }
        ClaudeCheck.shared.recheckIfStale()
        runningHooks[id] = RunningHook(runID: UUID(), name: first.name)
        cancelledHooks.remove(id)
        // Earlier runs' output is not the meeting.
        source.hookRuns = nil
        let meetings = settings.meetingLearnVoices ? store.meetings : nil
        let folder = URL(fileURLWithPath: settings.askClaudeFolder, isDirectory: true)
        let model = settings.askClaudeModel
        let tools = settings.askClaudeTools
        let permissionMode = settings.askClaudePermissionMode
        let userSystemPrompt = settings.askClaudeSystemPrompt
        DebugLog.write("Hooks: running \(counted(hooks.count, "hook")) on meeting \(id)")
        Task { [weak self] in
            // Who each voice sounds like, beside the names the meeting holds.
            var voices: [String: Meeting.Speaker.VoiceGuess] = [:]
            if let meetings { voices = await VoiceLibrary.shared.likeliest(for: source, among: meetings) }
            let transcript = TranscriptRender.markdown(source, voices: voices)
            var failures = 0
            for hook in hooks {
                guard let self, !self.cancelledHooks.contains(id) else { break }
                let runID = UUID()
                self.runningHooks[id] = RunningHook(runID: runID, name: hook.name)
                var answer = ClaudeRun.Answer(text: "Claude Code isn't installed. Get it at claude.com/claude-code.", seconds: 0, costUSD: nil, failed: true)
                var calls: [Meeting.ToolCall]?
                if let run = ClaudeRun.hook(prompt: hook.prompt, transcript: transcript, folder: folder, model: model, allowedTools: tools,
                                            permissionMode: permissionMode, userSystemPrompt: userSystemPrompt) {
                    self.hookRuns[id] = run
                    ClaudeLive.shared.start(runID, prompt: hook.prompt, run: run) { [weak self] in self?.cancelHooks(id) }
                    answer = await run.answer()
                    ClaudeLive.shared.finish(runID)
                    calls = ClaudeLive.shared.calls(runID)
                    self.hookRuns[id] = nil
                }
                if self.cancelledHooks.contains(id) {
                    answer = ClaudeRun.Answer(text: "Cancelled.", seconds: answer.seconds, costUSD: answer.costUSD, failed: true)
                }
                if answer.failed { failures += 1 }
                self.keep(Meeting.HookRun(id: runID, name: hook.name, prompt: hook.prompt, ranAt: Date(), output: answer.text, failed: answer.failed, sessionID: answer.sessionID, calls: calls), in: id)
            }
            guard let self else { return }
            self.runningHooks[id] = nil
            let cancelled = self.cancelledHooks.remove(id) != nil
            DebugLog.write("Hooks: \(counted(hooks.count, "hook")) on meeting \(id) \(cancelled ? "cancelled" : "done"), \(failures) failed")
            // Cancelled from the page, which shows how far they got. A prompt or
            // answer standing in the pill is left alone too.
            guard !cancelled, !self.overlay.model.state.isStanding else { return }
            self.toast(.meetingHooksDone(id: id, ran: hooks.count, failed: failures))
        }
    }

    /// Stops the meeting's running hook and skips the ones after it.
    private func cancelHooks(_ id: UUID) {
        guard runningHooks[id] != nil else { return }
        cancelledHooks.insert(id)
        hookRuns[id]?.cancel()
    }

    private func keep(_ run: Meeting.HookRun, in id: UUID) {
        guard var meeting = store.meeting(id) else { return }
        meeting.hookRuns = Meeting.HookRun.union(meeting.hookRuns ?? [], [run])
        store.save(meeting)
    }

    // MARK: System audio test

    /// Taps our own process while a cue plays and reports whether signal
    /// arrived: the only check there is for the grant (docs/meetings.md D13).
    func testSystemAudio() {
        guard systemAudioTest != .testing, let mic = MeetingCapture.microphone(preferredUID: settings.connectedMicrophoneUID()),
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
    private func toast(_ state: OverlayModel.State, onTimeout: (@MainActor () -> Void)? = nil) {
        toastTask?.cancel()
        // Whatever replaces an answer's pill takes the answer off camera too.
        CameraFeed.shared.clear()
        overlay.showMeeting(state)
        guard !state.isStanding else { return }
        toastTask = Task { [weak self] in
            let ranOut = await ToastTiming.countDown(counting: { self?.overlay.model.isCounting(state) })
            guard ranOut, let self else { return }
            onTimeout?()
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
            let ranOut = await ToastTiming.countDown(.seconds(Fixed.meetingTranscribeAskSeconds), deadline: nil, counting: { self?.overlay.model.isCounting(state) })
            guard ranOut, let self else { return }
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

    // MARK: Questions for Claude

    /// Records the user's answer to the question the pill offered, and
    /// keeps a question not asked in its meeting; an asked one is kept with
    /// its answer.
    private func logAnswer(_ answer: QuestionLog.Answer) {
        guard let id = offeredLogID, let question = offered else { return }
        offeredLogID = nil
        QuestionLog.append(QuestionLog.Entry(id: id, at: Date(), step: .answered, question: question.text, meeting: offeredMeetingID, answer: answer))
        let outcome: Meeting.Question.Outcome? = switch answer {
        case .ask: nil
        case .no: .dismissed
        case .ignored: .ignored
        }
        guard let outcome else { return }
        keep(Meeting.Question(atMs: meetingMs(question.start), text: question.text, outcome: outcome), meeting: offeredMeetingID, dictation: offeredDictationID)
    }

    /// Seconds since the recording's first audio; 0 with nothing recording.
    private var secondsRecorded: TimeInterval {
        recorder.flatMap { recorder in
            recorder.firstHostTime > 0 ? MeetingCapture.seconds(fromHostTime: recorder.firstHostTime, to: mach_absolute_time()) : nil
        } ?? 0
    }

    /// Seconds into the live transcript as meeting time, which counts the
    /// pre-roll; the live transcript starts at the click.
    private func meetingMs(_ seconds: TimeInterval) -> Int {
        (recordingMeeting?.preRollMs ?? 0) + Int(seconds * 1000)
    }

    /// A checked question, offered while nothing else is being asked.
    /// A dictation that asks by name ("TMI, can you…"): offered in the pill
    /// instead of typed, with the meeting's transcript when one is recording.
    func offerDictated(_ request: String, dictation: UUID) {
        let id = UUID()
        QuestionLog.append(QuestionLog.Entry(id: id, at: Date(), step: .checked, question: request, meeting: recording?.id, verdict: .addressed))
        let now = secondsRecorded
        offer(SpottedQuestion(text: request, track: .mic, start: now, end: now, addressed: true), logID: id, dictation: dictation)
    }

    private func offer(_ question: SpottedQuestion, logID: UUID, dictation: UUID? = nil) {
        let answering = { (state: OverlayModel.State?) -> Bool in
            if case .meetingAnswer = state { return true }
            return false
        }
        // An open answer is not swept away by the next question.
        guard askRun == nil, !answering(overlay.model.state), !answering(overlay.model.pendingMeeting) else { return }
        // A question offered and left unanswered says nothing either way.
        if offeredLogID != nil { logAnswer(.ignored) }
        offered = question
        offeredLogID = logID
        offeredMeetingID = recording?.id
        offeredDictationID = dictation
        toast(.meetingQuestion(text: question.text)) { [weak self] in self?.logAnswer(.ignored) }
    }

    /// What the menu's ask shows in the pill and on the meeting page, in
    /// turn, before the question it found.
    private static let transcribingStep = "transcribing"
    private static let findingStep = "finding question"

    /// The menu's ask: the whole transcript so far goes to Claude, which
    /// answers its latest question.
    func askLatestQuestion() {
        askClaude(Self.findingStep, prompt: "Answer the latest question in the transcript.")
    }

    /// `prompt` is what Claude is told; by default, the question itself.
    private func askClaude(_ question: String, heardAt: TimeInterval? = nil, prompt: String? = nil) {
        // Asked while another answer is coming: the new one wins.
        if askRun != nil || self.asking != nil { cancelAsk() }
        ClaudeCheck.shared.recheckIfStale()
        toastTask?.cancel()
        let shown = prompt != nil && recording != nil ? Self.transcribingStep : question
        var asking = OverlayModel.State.meetingAsking(text: shown)
        overlay.showMeeting(asking)
        CameraFeed.shared.asking()
        let dictationID = offered?.text == question ? offeredDictationID : nil
        let runID = UUID()
        if recording != nil || dictationID != nil {
            let heard = heardAt ?? (offered?.text == question ? offered?.start : nil) ?? secondsRecorded
            self.asking = (Meeting.Question(atMs: meetingMs(heard), text: shown, outcome: .asked, runID: runID), recording?.id, dictationID)
        }
        askPreparing = true
        askingIn = self.asking.flatMap { asked in asked.meeting.map { ($0, asked.question) } }
        openTarget = self.asking.map { ($0.meeting, $0.dictation) }
        askOpened = false
        overlay.model.askOpens = openTarget != nil
        let folder = URL(fileURLWithPath: settings.askClaudeFolder, isDirectory: true)
        let tools = settings.askClaudeTools
        let model = settings.askClaudeModel
        let userSystemPrompt = settings.askClaudeSystemPrompt
        let permissionMode = settings.askClaudePermissionMode
        Task { [weak self] in
            let transcript = await self?.transcribeSoFar().map { TranscriptRender.markdown($0) }
            // Cancelled while the transcript was gathered.
            guard let self, self.askOpened || self.overlay.model.state == asking || self.overlay.model.pendingMeeting == asking else { return }
            // The page shows the new text, and the pill too while it is up.
            let show = { (text: String) in
                self.asking?.question.text = text
                self.askingIn?.question.text = text
                if !self.askOpened, self.overlay.model.state == asking || self.overlay.model.pendingMeeting == asking {
                    asking = .meetingAsking(text: text)
                    self.overlay.showMeeting(asking)
                }
            }
            // The menu's ask names no question: Haiku finds it in the transcript.
            var question = question
            var prompt = prompt
            if prompt != nil {
                show(Self.findingStep)
                if let transcript, let extract = ClaudeRun.latestQuestion(in: transcript) {
                    self.askRun = extract
                    let found = await extract.answer()
                    guard self.askRun === extract else { return }
                    let text = found.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !found.failed, !text.isEmpty {
                        question = text
                        prompt = nil
                        show(text)
                    }
                }
            }
            guard let run = ClaudeRun.answering(prompt: prompt ?? "The question: \(question)", transcript: transcript, folder: folder, model: model, allowedTools: tools, permissionMode: permissionMode,
                                                    userSystemPrompt: userSystemPrompt) else {
                self.showAnswer(question, ClaudeRun.Answer(text: "Claude Code isn't installed. Get it at claude.com/claude-code.",
                                                           seconds: 0, costUSD: nil, failed: true), replacing: asking)
                return
            }
            self.askRun = run
            self.askPreparing = false
            let liveID = dictationID ?? runID
            ClaudeLive.shared.start(liveID, prompt: question, run: run) { [weak self] in self?.cancelAsk() }
            let answer = await run.answer()
            ClaudeLive.shared.finish(liveID)
            // Cancelled: the pill is already down and the run let go.
            guard self.askRun === run else { return }
            self.askRun = nil
            self.showAnswer(question, answer, calls: ClaudeLive.shared.calls(liveID), replacing: asking)
        }
    }

    /// Transcribes the recording so far onto the live meeting, whose page
    /// shows it until the full pass replaces it. Nil with nothing recording.
    @discardableResult func transcribeSoFar() async -> Meeting? {
        guard let recorder, let liveID = recording?.id else { return nil }
        transcribingSoFar = true
        defer { transcribingSoFar = false }
        guard let soFar = await Self.transcriptSoFar(recorder, id: liveID, names: roster?.peek()) else { return nil }
        if recording?.id == liveID, var shown = store.meeting(liveID), shown.transcription.state != .done {
            shown.paragraphs = soFar.paragraphs
            shown.speakers = soFar.speakers
            store.save(shown)
        }
        return soFar
    }

    /// The recording so far through the meeting transcriber, as its
    /// meeting with speakers. Nil when the copy or transcription fails.
    nonisolated private static func transcriptSoFar(_ recorder: MeetingRecorder, id: UUID, names: MeetingNames?) async -> Meeting? {
        // The live meeting's id, so the voices learned are its own and its page can suggest names.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("so-far-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            let snapshot = try recorder.snapshot(id: id, into: folder, names: names)
            let meeting = await MeetingTranscriber.run(snapshot, folder: folder, save: { _ in }) { _ in }
            return meeting.transcription.state == .done ? meeting : nil
        } catch {
            DebugLog.write("Ask transcript failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Keeps a question with the meeting it was heard in and the dictation
    /// that asked it, either or both.
    private func keep(_ question: Meeting.Question, meeting: UUID?, dictation: UUID?) {
        if let meeting { keep(question, in: meeting) }
        if let dictation {
            var asked = question
            asked.atMs = 0
            Store.shared.setQuestion(asked, onDictation: dictation)
        }
    }

    /// Adds an answered question to its meeting, recording or finished.
    private func keep(_ question: Meeting.Question, in id: UUID) {
        if var recorded = recordingMeeting, recorded.id == id {
            recorded.questions = Meeting.Question.union(recorded.questions ?? [], [question])
            recordingMeeting = recorded
        }
        guard var meeting = store.meeting(id) else { return }
        meeting.questions = Meeting.Question.union(meeting.questions ?? [], [question])
        store.save(meeting)
    }

    /// `-previewAnswer YES` walks the answer pill from offer through asking
    /// to an answer, for looking at it without a call.
    func previewAnswerIfAsked() {
        guard UserDefaults.standard.bool(forKey: "previewAnswer") else { return }
        let question = "How many calls did we have last week?"
        let answer = ClaudeRun.Answer(
            text: "**1,284 inbound calls** last week (Monday 29 September to Sunday 5 October), up 6% on the week before.\n\nCounted from the calls table: inbound calls that connected, grouped by day. Tuesday was the busiest day with 241.",
            seconds: 23, costUSD: 0.08, failed: false)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            overlay.showMeeting(.meetingQuestion(text: question))
            try? await Task.sleep(for: .seconds(3))
            overlay.showMeeting(.meetingAsking(text: question))
            try? await Task.sleep(for: .seconds(3))
            showAnswer(question, answer, replacing: .meetingAsking(text: question))
        }
    }

    /// Opens the answer in the pill that asked, or parks it behind the cloud.
    private func showAnswer(_ question: String, _ answer: ClaudeRun.Answer, calls: [Meeting.ToolCall]? = nil, replacing asking: OverlayModel.State) {
        if var kept = self.asking {
            self.asking = nil
            kept.question.answer = answer.text
            kept.question.sessionID = answer.sessionID
            kept.question.calls = calls
            keep(kept.question, meeting: kept.meeting, dictation: kept.dictation)
        }
        askingIn = nil
        askPreparing = false
        guard !askOpened else { return }
        if overlay.model.pendingMeeting == asking { overlay.model.pendingMeeting = nil }
        if answer.failed { CameraFeed.shared.clear() } else { CameraFeed.shared.answer(question: question, answer: answer.text) }
        overlay.model.answerExpanded = true
        overlay.showMeeting(.meetingAnswer(text: question, answer: answer))
    }

    func cancelAsk() {
        askRun?.cancel()
        askRun = nil
        askingIn = nil
        askPreparing = false
        if var kept = asking {
            asking = nil
            kept.question.outcome = .cancelled
            keep(kept.question, meeting: kept.meeting, dictation: kept.dictation)
        }
        dismissToast()
    }

    private func dismissToast() {
        toastTask?.cancel()
        CameraFeed.shared.clear()
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
        case .otherCall: "otherCall"
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
