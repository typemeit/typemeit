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
        /// A call is confirmed: record it? Stays until answered.
        case meetingPrompt(app: ProcessOwner.Owner)
        /// The tap delivered nothing for `Fixed.meetingSilentSeconds`.
        case meetingSystemAudioOff
        case meetingSaved(id: UUID)
        /// Transcribe now? Says okay itself after `Fixed.meetingTranscribeAskSeconds`.
        case meetingTranscribeAsk(id: UUID)
        case meetingFailed(id: UUID)
        /// Stays until dismissed.
        case meetingDiskFull(id: UUID)
        /// The call dropped and rejoined; the recording carried on.
        case meetingResumed(app: ProcessOwner.Owner)
        case meetingFolderUnavailable

        var isMeeting: Bool {
            switch self {
            case .meetingPrompt, .meetingSystemAudioOff, .meetingSaved, .meetingTranscribeAsk, .meetingFailed, .meetingDiskFull, .meetingResumed, .meetingFolderUnavailable: true
            default: false
            }
        }

        /// Stays up until a button answers it, never on a timer.
        var isStanding: Bool {
            switch self {
            case .updateReady, .meetingPrompt, .meetingDiskFull: true
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
        case .copyPrompt, .learned, .undone, .updateReady, .updateFailed: .pill
        case .meetingPrompt, .meetingSystemAudioOff, .meetingSaved, .meetingTranscribeAsk, .meetingFailed, .meetingDiskFull, .meetingResumed, .meetingFolderUnavailable: .pill
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
    var onPin: (@MainActor () -> Void)?
    var onStop: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?
    var onCopy: (@MainActor () -> Void)?
    var onKeep: (@MainActor () -> Void)?
    var onUndo: (@MainActor () -> Void)?
    var onInstall: (@MainActor () -> Void)?
    var onOpenIntelligence: (@MainActor () -> Void)?
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
}
