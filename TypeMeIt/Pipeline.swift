import AppKit
import Foundation
import Observation

/// One dictation from Fn down to paste, and everything the pill needs to know.
@MainActor
@Observable
final class Pipeline {
    static let shared = Pipeline()

    enum Phase: Equatable { case idle, recording, transcribing, cleaningUp }
    private(set) var phase: Phase = .idle { didSet { if phase == .idle { Updates.shared.remind() } } }
    let shortcuts = Shortcuts()
    let overlay = OverlayPanel()
    let capture = AudioCapture()
    private var settings: Settings { Settings.shared }
    private var store: Store { Store.shared }

    private var recordingStartedAt: Date?
    private var pinned = false
    private var generation = 0
    private var copyPromptTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var lastRecordingFirstBuffer = false
    /// Screen terms for the dictation in progress: nil until the read
    /// finishes. The read starts with the recording and is never waited
    /// for; a dictation shorter than the read goes without.
    private var screenTerms: [String]?
    /// The last read, reused when the next dictation goes into the same
    /// window soon after, so a run of short dictations is not a run of reads.
    private var lastScreen: (pid: pid_t, title: String?, at: ContinuousClock.Instant, terms: [String])?

    private init() {
        shortcuts.onEvent = { [weak self] event in self?.handle(event) }
        capture.onLevel = { [weak self] level in
            Task { @MainActor in self?.overlay.setLevel(level) }
        }
        capture.onFirstBuffer = { [weak self] in
            Task { @MainActor in
                guard let self, self.overlay.model.state == .arming else { return }
                self.overlay.show(.recording)
            }
        }
        overlay.model.onPin = { [weak self] in self?.shortcuts.pinFromOverlay() }
        overlay.model.onStop = { [weak self] in self?.shortcuts.stopFromOverlay() }
        overlay.model.onCancel = { [weak self] in
            guard let self else { return }
            if case .copyPrompt = self.overlay.model.state { self.dismissCopyPrompt(); return }
            if case .learned = self.overlay.model.state { self.keepLearned(); return }
            self.shortcuts.cancelFromOverlay()
        }
        overlay.model.onCopy = { [weak self] in self?.copyFromPrompt() }
        overlay.model.onOpenAccessibility = { NSWorkspace.shared.open(SecureInput.accessibilitySettingsURL) }
        overlay.model.onKeep = { [weak self] in self?.keepLearned() }
        overlay.model.onUndo = { [weak self] in self?.undoLearned() }
        overlay.model.onOpenIntelligence = { [weak self] in
            self?.keepLearned()
            AppState.shared.settingsTab = .intelligence
            NotificationCenter.default.post(name: MenuBarLabel.openSettings, object: nil)
        }
        overlay.model.onInstall = { [weak self] in self?.toastTask?.cancel(); self?.overlay.hide(); Updates.shared.install() }
    }

    func start() {
        Feedback.preload()
        if !shortcuts.install() {
            Log.app.error("Shortcuts not installed; Accessibility is missing")
        }
        if settings.postProcessingEnabled, settings.screenContextEnabled { Task.detached { await ScreenContext.prewarm() } }
        // Loading the model takes seconds; done here, the first dictation does not pay for it.
        if ModelStore.isInstalled { Task { await Transcriber.shared.preload() } }
    }

    var isBusy: Bool { phase != .idle }

    // MARK: Events

    private func handle(_ event: ShortcutEvent) {
        switch event {
        case .recordingStarted: beginRecording()
        case .pinned:
            pinned = true
            if settings.audioFeedback { playWhileMuted(.pin) }
            if overlay.model.isRecording { overlay.show(.pinned) }
        case .recordingEnded: endRecording()
        case .cancelled: cancel()
        case .copyLastRequested: copyLast()
        }
    }

    /// The newest transcript with any text goes to the clipboard.
    private func copyLast() {
        guard let entry = Store.shared.history.last(where: { !$0.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        Output.copyToClipboard(entry.displayText)
        Log.app.info("Copied the newest transcript by shortcut")
    }

    /// The output device is muted while recording, so a cue played then has
    /// to lift the mute, sound, and put it back.
    private func playWhileMuted(_ kind: Feedback.Kind) {
        let gen = generation
        let wasMuted = OutputMute.restore()
        let wait = wasMuted ? 0.08 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { Feedback.play(kind) }
        guard wasMuted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + Feedback.duration(kind)) { [weak self] in
            if self?.phase == .recording, self?.generation == gen { OutputMute.mute() }
        }
    }

    private func beginRecording() {
        guard phase == .idle else { return }
        generation += 1
        phase = .recording
        pinned = false
        recordingStartedAt = Date()
        copyPromptTask?.cancel()
        toastTask?.cancel()
        ReadBack.shared.finishNow()
        shortcuts.setPhase(.recording)
        if settings.muteWhileRecording { OutputMute.mute() }
        if settings.pauseWhileRecording { MediaPause.pause() }
        do {
            try capture.start(uid: settings.microphoneUID)
        } catch {
            Log.audio.error("Could not start capture: \(error.localizedDescription)")
            phase = .idle
            shortcuts.setPhase(.idle)
            OutputMute.restore()
            MediaPause.resume()
            return
        }
        overlay.show(.arming)
        screenTerms = nil
        if settings.postProcessingEnabled {
            Task { await PostProcessor.shared.prewarm() }
            if settings.screenContextEnabled { readScreen(generation: generation) }
        }
        Task { await Transcriber.shared.preload() }
    }

    /// Reads the frontmost window in the background and stores the terms
    /// for dictation `gen`, unless the same window was read within
    /// `Fixed.screenReadReuse`, in which case that read is used as is.
    private func readScreen(generation gen: Int) {
        guard let target = Frontmost.capture(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        if let last = lastScreen, last.pid == pid, last.title == target.windowTitle, ContinuousClock.now - last.at < Fixed.screenReadReuse {
            screenTerms = last.terms
            return
        }
        let customWords = settings.customWords
        Task { [weak self] in
            let lines = await ScreenContext.captureLines(pid: pid)
            let terms = await ScreenContext.terms(from: lines, excluding: customWords)
            guard let self else { return }
            self.lastScreen = (pid, target.windowTitle, ContinuousClock.now, terms)
            if self.generation == gen { self.screenTerms = terms }
        }
    }

    private func cancel() {
        let wasRecording = phase == .recording
        generation += 1
        phase = .idle
        shortcuts.setPhase(.idle)
        if wasRecording { capture.cancel() }
        OutputMute.restore()
        MediaPause.resume()
        Task { Transcriber.shared.cancel() }
        PostProcessor.shared.cancel()
        overlay.hide()
    }

    private func endRecording() {
        guard phase == .recording else { return }
        let gen = generation
        let pcm = capture.stop()
        let duration = Double(pcm.count) / 16000
        let durationMs = Int(duration * 1000)
        let wasMuted = OutputMute.restore()
        MediaPause.resume()
        if settings.audioFeedback {
            // The device takes a moment to come back from mute; a cue played
            // in the same instant is lost.
            let wait = wasMuted ? 0.08 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { Feedback.play(.stop) }
        }

        if duration < Fixed.minimumRecordingSeconds || AudioCapture.peak(pcm) < Fixed.silencePeak {
            Log.app.info("Empty recording discarded (\(duration) s)")
            DebugLog.write("Dictation discarded: \(durationMs) ms of audio, \(duration < Fixed.minimumRecordingSeconds ? "too short" : "silent")")
            phase = .idle
            shortcuts.setPhase(.idle)
            overlay.hide()
            return
        }

        let target = Frontmost.capture()
        let entryId = UUID()
        let recordingFile = settings.keepRecordings && settings.historyLimit >= 0 ? RecordingArchive.save(pcm, id: entryId) : nil
        phase = .transcribing
        shortcuts.setPhase(.transcribing)
        overlay.show(.transcribing)

        Task { [weak self] in
            guard let self else { return }
            let raw: Transcriber.Transcript
            let transcribeStart = ContinuousClock.now
            do {
                raw = try await Transcriber.shared.transcribeScored(pcm)
            } catch {
                if gen == self.generation {
                    Log.transcriber.error("\(error.localizedDescription)")
                    DebugLog.write("Dictation discarded: transcription failed (\(error.localizedDescription))")
                    self.finishIdle(discarding: recordingFile)
                }
                return
            }
            guard gen == self.generation else { return }
            let transcribeMs = Pipeline.elapsedMs(since: transcribeStart)
            Log.transcriber.info("Transcribed \(durationMs) ms of audio in \(transcribeMs) ms")
            await self.deliver(raw: raw, durationMs: durationMs, transcribeMs: transcribeMs, target: target, entryId: entryId, recordingFile: recordingFile, generation: gen)
        }
    }

    /// Returns to idle as if the dictation never happened. A recording saved
    /// for it would otherwise sit in the archive with no history entry.
    private func finishIdle(discarding recordingFile: String? = nil) {
        if let recordingFile { RecordingArchive.delete([recordingFile]) }
        phase = .idle
        shortcuts.setPhase(.idle)
        overlay.hide()
    }

    private static func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        (ContinuousClock.now - start).milliseconds
    }

    private func deliver(raw: Transcriber.Transcript, durationMs: Int, transcribeMs: Int, target: Frontmost.Target?, entryId: UUID, recordingFile: String?, generation gen: Int) async {
        if ModelText.isBlank(raw.text) {
            DebugLog.write("Dictation discarded: transcript blank after \(durationMs) ms of audio")
            finishIdle(discarding: recordingFile)
            return
        }
        let styles = settings.writingStyles
        let requested = settings.postProcessingEnabled
        let matched = CustomWordMatcher.apply(raw.matcherWords, terms: store.terms(for: settings.customWords))
        if matched.fixes > 0 { Log.postProcess.info("Custom words replaced \(matched.fixes) run(s)") }
        var finalText = matched.text
        var postProcessed: String?
        var postProcessMs: Int?

        if requested {
            phase = .cleaningUp
            shortcuts.setPhase(.cleaningUp)
            overlay.show(.cleaningUp)
            let screenTerms = self.screenTerms ?? []
            if self.screenTerms == nil, settings.screenContextEnabled { Log.screenContext.info("Screen read not finished; cleaning up without it") }
            if !screenTerms.isEmpty { Log.screenContext.info("Screen terms: \(screenTerms.joined(separator: ", "), privacy: .private)") }
            let start = ContinuousClock.now
            let cleaned = await PostProcessor.shared.clean(matched, customWords: settings.customWords, screenTerms: screenTerms, styles: styles)
            let ms = Pipeline.elapsedMs(since: start)
            postProcessMs = ms
            Log.postProcess.info("Post-processing took \(ms) ms (\(cleaned.applied ? "applied" : "no result, local clean-up only"))")
            guard gen == generation else { return }
            if cleaned.applied { postProcessed = cleaned.text }
            finalText = cleaned.text
        } else {
            finalText = LocalCleanup.run(finalText)
        }
        // Fillers alone ("um", "uh") clean down to nothing; that is silence, not a dictation.
        if finalText.isEmpty {
            DebugLog.write("Dictation discarded: clean-up left nothing of \"\(DebugLog.excerpt(raw.text))\"")
            finishIdle(discarding: recordingFile)
            return
        }

        let typed = finalText
        if settings.appendTrailingSpace { finalText += " " }
        let focusedIsTextInput = Focus.focusedElementIsTextInput()
        let paste = await Output.paste(finalText, autoSubmit: settings.autoSubmit, autoSubmitKey: settings.autoSubmitKey)
        let pasted = paste.posted
        guard gen == generation else { return }

        let entry = HistoryEntry(
            id: entryId, timestamp: Date(), transcript: raw.text, postProcessed: postProcessed, postProcessRequested: requested, typed: typed,
            durationMs: durationMs, transcribeMs: transcribeMs, postProcessMs: postProcessMs, appId: target?.appId, appName: target?.appName, windowTitle: target?.windowTitle,
            dictionaryFixes: matched.fixes, recordingFile: recordingFile)
        store.append(entry, limit: settings.historyLimit)

        phase = .idle
        shortcuts.setPhase(.idle)

        if pasted, focusedIsTextInput == true, settings.learnFromCorrections {
            ReadBack.shared.start(pasted: finalText, historyId: entry.id, appId: target?.appId)
        }

        let appName = target?.appName ?? "unknown app"
        let focus = focusedIsTextInput.map { $0 ? "text input" : "not text input" } ?? "unknown"
        guard settings.copyPromptEnabled else {
            DebugLog.write("Delivery to \(appName): focus \(focus), Cmd+V \(pasted ? "posted" : "not posted") → done")
            overlay.hide()
            return
        }
        if !pasted || focusedIsTextInput == false {
            DebugLog.write("Delivery to \(appName): focus \(focus), Cmd+V \(pasted ? "posted" : "not posted") → copy prompt")
            showCopyPrompt(finalText, cantType: !pasted)
            return
        }
        // The role could not rule the paste out; whether anything reads the
        // clipboard can. A focused container (Zed's window, Finder's list)
        // looks the same either way.
        overlay.hide()
        let landed = await paste.landed(within: Fixed.pasteLandedWaitMs)
        guard gen == generation else { return }
        DebugLog.write("Delivery to \(appName): focus \(focus), Cmd+V posted, clipboard \(landed ? "read → done" : "not read within \(Fixed.pasteLandedWaitMs) ms → copy prompt")")
        if !landed { showCopyPrompt(finalText, cantType: false) }
    }

    // MARK: Copy prompt

    private var copyPromptText = ""

    private func showCopyPrompt(_ text: String, cantType: Bool) {
        copyPromptText = text
        overlay.show(.copyPrompt(cantType: cantType))
        copyPromptTask?.cancel()
        copyPromptTask = Task { [weak self] in
            try? await Task.sleep(for: Fixed.copyPromptTimeout)
            guard !Task.isCancelled, let self, case .copyPrompt = self.overlay.model.state else { return }
            self.overlay.hide()
        }
    }

    private func copyFromPrompt() {
        Output.copyToClipboard(copyPromptText)
        overlay.model.copied = true
        copyPromptTask?.cancel()
        copyPromptTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.overlay.hide()
        }
    }

    private func dismissCopyPrompt() {
        copyPromptTask?.cancel()
        overlay.hide()
    }

    func copyLastTranscript() {
        if let e = store.newest { Output.copyToClipboard(e.displayText) }
    }

    // MARK: Learned-words toast

    private var toastBatch: UUID?

    func showLearnedToast(batchId: UUID, words: [String]) {
        guard !words.isEmpty else { return }
        toastBatch = batchId
        showToast(.learned(batchId: batchId, words: words))
    }

    /// Shows a pill that hides itself after `ToastTiming.timeout`, not
    /// counting time the pointer rests on it. Only while nothing else is on
    /// screen: a toast must not cover a dictation.
    /// - Returns: false when the overlay was busy and nothing was shown.
    @discardableResult
    func showToast(_ state: OverlayModel.State) -> Bool {
        guard phase == .idle, overlay.model.state == .hidden else { return false }
        overlay.show(state)
        toastTask?.cancel()
        // A ready update stays up until it is installed or put off; the
        // buttons are the only way it leaves.
        if case .updateReady = state { return true }
        toastTask = Task { [weak self] in
            var remaining = ToastTiming.timeout
            let step: Duration = .milliseconds(100)
            let deadline = ContinuousClock.now + ToastTiming.safetyHide
            while remaining > .zero, ContinuousClock.now < deadline {
                try? await Task.sleep(for: step)
                guard !Task.isCancelled, let self else { return }
                if !self.overlay.model.toastPaused { remaining -= step }
            }
            guard !Task.isCancelled, let self, self.overlay.model.state == state else { return }
            self.overlay.hide()
        }
        return true
    }

    private func keepLearned() {
        toastTask?.cancel()
        if case .updateReady(let version) = overlay.model.state { Updates.shared.putOff(version) }
        overlay.hide()
    }

    private func undoLearned() {
        guard let batch = toastBatch else { overlay.hide(); return }
        toastTask?.cancel()
        LearningCoordinator.shared.undo(batchId: batch)
        overlay.show(.undone)
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: ToastTiming.undoneLinger)
            guard !Task.isCancelled else { return }
            self?.overlay.hide()
        }
    }
}
