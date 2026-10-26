import Foundation
import Observation

/// What the overlay shows. Driven by the pipeline, read by CloudView and
/// PillView.
@MainActor
@Observable
final class OverlayModel {
    enum State: Equatable {
        case hidden
        case arming
        case recording
        case pinned
        case transcribing
        case cleaningUp
        /// The text had nowhere to land. `cantType` when the paste itself could
        /// not be posted, which means the accessibility grant is missing.
        case copyPrompt(cantType: Bool)
        case learned(batchId: UUID, words: [String])
        case undone
        /// An update is downloaded and waiting for the install button.
        case updateReady(version: String)
        /// An update was found but its download failed; Sparkle retries on the next hourly check.
        case updateFailed(version: String)
        /// The microphone would not start when a dictation began.
        case micFailed
        /// A call is confirmed: record it? Stays until answered.
        case meetingPrompt(app: ProcessOwner.Owner)
        /// The tap delivered nothing for `Fixed.meetingSilentSeconds`.
        case meetingSystemAudioOff
        /// With `hooks`, it offers to run the meeting's hooks.
        case meetingSaved(id: UUID, hooks: Bool)
        /// The hooks run from a pill or a page have all finished.
        case meetingHooksDone(id: UUID, ran: Int, failed: Int)
        /// Transcribe now? Says okay itself after `Fixed.meetingTranscribeAskSeconds`.
        case meetingTranscribeAsk(id: UUID)
        case meetingFailed(id: UUID)
        /// Stays until dismissed.
        case meetingDiskFull(id: UUID)
        /// The call dropped and rejoined; the recording carried on.
        case meetingResumed(app: ProcessOwner.Owner)
        case meetingFolderUnavailable
        /// A check of Claude Code the user did not start failed (`ClaudeCheck`).
        case claudeCheckFailed
        /// A question heard in the meeting, offered to Claude Code.
        case meetingQuestion(text: String)
        /// Claude Code is answering. Stays until it answers or is cancelled.
        case meetingAsking(text: String)
        /// Claude's answer, open under its question. Stays until dismissed.
        case meetingAnswer(text: String, answer: ClaudeRun.Answer)

        var isMeeting: Bool {
            switch self {
            case .meetingPrompt, .meetingSystemAudioOff, .meetingSaved, .meetingHooksDone, .meetingTranscribeAsk, .meetingFailed, .meetingDiskFull, .meetingResumed, .meetingFolderUnavailable, .claudeCheckFailed, .meetingQuestion, .meetingAsking, .meetingAnswer: true
            default: false
            }
        }

        /// Stays up until a button answers it, never on a timer.
        var isStanding: Bool {
            switch self {
            case .updateReady, .meetingPrompt, .meetingDiskFull, .meetingAsking, .meetingAnswer: true
            default: false
            }
        }
    }

    /// Which view a state is shown in: the dictation itself is the cloud,
    /// the prompts and toasts afterwards are the pill.
    enum Presentation: Equatable { case none, cloud, pill }

    var state: State = .hidden
    var level: Float = 0
    var copied = false
    var toastPaused = false

    /// Whether `toast`'s countdown runs: it is the one on screen and the
    /// pointer is not resting on it.
    func isCounting(_ toast: State) -> Bool { state == toast && !toastPaused }
    /// Whether the answer pill shows the answer or only its question.
    var answerExpanded = true
    /// When the cloud last arrived. Each dictation gets a new one, so the
    /// cloud grows in again even if the previous one had not finished fading.
    var shownAt: Date?
    /// When the cloud started to puff out, or nil while it is still wanted.
    var departedAt: Date?
    /// When lightning last struck the cloud: on the pin, and as the
    /// dictation ended and transcription began.
    var struckAt: Date?
    /// What is under the cloud, when the screen has been sampled. Nil falls
    /// back to the appearance.
    var backdrop: ScreenSampler.Backdrop?

    /// A meeting state that arrived while the cloud was up, shown when it
    /// leaves (docs/meetings.md 7.7).
    var pendingMeeting: State?

    var presentation: Presentation {
        switch state {
        case .hidden: .none
        case .arming, .recording, .pinned, .transcribing, .cleaningUp: .cloud
        case .copyPrompt, .learned, .undone, .updateReady, .updateFailed, .micFailed: .pill
        case .meetingPrompt, .meetingSystemAudioOff, .meetingSaved, .meetingHooksDone, .meetingTranscribeAsk, .meetingFailed, .meetingDiskFull, .meetingResumed, .meetingFolderUnavailable, .claudeCheckFailed: .pill
        case .meetingQuestion, .meetingAsking, .meetingAnswer: .pill
        }
    }

    /// Pill width per state, from the design.
    var width: CGFloat {
        switch state {
        case .copyPrompt(cantType: true): 470
        case .copyPrompt: 368
        default: 320
        }
    }

    var isRecording: Bool {
        switch state {
        case .arming, .recording, .pinned: true
        default: false
        }
    }

    // Actions wired by the pipeline.
    /// Set by the cross: the next hide takes the panel down without a fade.
    var closeNow = false
    var onPin: (@MainActor () -> Void)?
    var onStop: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?
    var onCopy: (@MainActor () -> Void)?
    var onKeep: (@MainActor () -> Void)?
    var onUndo: (@MainActor () -> Void)?
    var onInstall: (@MainActor () -> Void)?
    var onOpenDictionary: (@MainActor () -> Void)?
    var onOpenAccessibility: (@MainActor () -> Void)?
    // Meetings, wired by the coordinator.
    var onRecordMeeting: (@MainActor () -> Void)?
    var onDeclineMeeting: (@MainActor () -> Void)?
    var onStopMeeting: (@MainActor () -> Void)?
    var onShowMeeting: (@MainActor (UUID?) -> Void)?
    /// The transcribe prompt's okay (true) and later (false).
    var onTranscribeMeeting: (@MainActor (UUID, Bool) -> Void)?
    var onOpenSystemAudio: (@MainActor () -> Void)?
    /// The cross on any meeting toast.
    var onDismissMeeting: (@MainActor () -> Void)?
    var onAskClaude: (@MainActor (String) -> Void)?
    /// The pill's no: not a question to ask.
    var onDeclineQuestion: (@MainActor (String) -> Void)?
    var onCancelAsk: (@MainActor () -> Void)?
    /// The asking pill shows open: Claude is answering for a dictation or a meeting with a page.
    var askOpens = false
    /// Opens the page of the dictation or meeting Claude is answering for.
    var onOpenAsk: (@MainActor () -> Void)?
    /// The saved pill's run hooks.
    var onRunHooks: (@MainActor (UUID) -> Void)?
    /// Opens settings on the Claude Code check.
    var onShowClaudeCheck: (@MainActor () -> Void)?
}
