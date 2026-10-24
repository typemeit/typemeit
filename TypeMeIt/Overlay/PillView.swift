import AppKit
import SwiftUI

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { nsView.material = material }
}

/// The prompt after a dictation, when an update is ready, or when a call
/// starts: the square pill, its mark, the message left-aligned after it, and
/// its buttons and cross on the right. A failure inverts to the slab, so it
/// never reads as a success.
struct PillView: View {
    @Bindable var model: OverlayModel

    var body: some View {
        prompt
            // The design width, stretching for a long learned word up to what
            // the panel can hold, then truncating the word's middle so both
            // ends still read.
            .frame(maxWidth: OverlayPanel.size.width - 40)
            .fixedSize(horizontal: true, vertical: false)
            .animation(.spring(duration: 0.46, bounce: 0.1), value: model.width)
            .onHover { model.toastPaused = $0 }
    }

    @ViewBuilder private var prompt: some View {
        // One view from offer to answer, so the pill grows instead of being replaced.
        if let (question, stage) = answerStage {
            AnswerPill(model: model, question: question, stage: stage)
        } else {
            promptForState
        }
    }

    private var answerStage: (String, AnswerPill.Stage)? {
        switch model.state {
        case .meetingQuestion(let text): (text, .offered)
        case .meetingAsking(let text): (text, .asking)
        case .meetingAnswer(let text, let answer): (text, .answered(answer))
        default: nil
        }
    }

    @ViewBuilder private var promptForState: some View {
        let width = model.width
        switch model.state {
        case .copyPrompt(let cantType):
            SquarePrompt(mark: .icon("akar-clipboard"), message: Text(cantType ? "accessibility is off, so it can't type" : "nowhere to type it"),
                         dismiss: "cancel", onDismiss: { model.closeNow = true; model.onCancel?() }, minWidth: width) {
                if cantType {
                    Button("system settings") { model.onOpenAccessibility?() }.buttonStyle(SquareButtonStyle(kind: .quiet))
                }
                Button(model.copied ? "copied" : "copy") { model.onCopy?() }
                    .buttonStyle(SquareButtonStyle(kind: .primary))
                    .help("copy transcript")
            }
        case .learned(_, let words):
            // The word itself in medium, kept as the user spelt it, since that
            // spelling is what was added.
            SquarePrompt(mark: .button("akar-sparkles", help: "open dictionary") { model.closeNow = true; model.onOpenDictionary?() },
                         message: words.count == 1 ? Text("added \(Text(words[0]).fontWeight(.medium)) to dictionary") : Text("learned \(counted(words.count, "word"))"),
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onKeep?() }, minWidth: width) {
                Button("undo") { model.onUndo?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .undone:
            SquarePrompt(message: Text("undone"), minWidth: width) {}
        case .updateReady(let v):
            SquarePrompt(mark: .icon("akar-sparkles"), message: Text("version \(Text(v).fontWeight(.medium)) is ready"),
                         dismiss: "later", onDismiss: { model.closeNow = true; model.onKeep?() }, minWidth: width) {
                Button("install") { model.onInstall?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .updateFailed(let v):
            SquarePrompt(mark: .icon("akar-sparkles"), message: Text("version \(v) didn't download"), failed: true,
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onKeep?() }, minWidth: width) {}
        case .meetingPrompt:
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("record this meeting?"),
                         dismiss: "not now", onDismiss: { model.closeNow = true; model.onDeclineMeeting?() }, minWidth: width) {
                Button("record") { model.onRecordMeeting?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingResumed(let app):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("recording again · \(app.name.lowercased())"),
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onDismissMeeting?() }, minWidth: width) {
                Button("stop") { model.onStopMeeting?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingSystemAudioOff:
            SquarePrompt(mark: .icon("akar-microphone"), message: Text("system audio is off"),
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onDismissMeeting?() }, minWidth: width) {
                Button("system settings") { model.onOpenSystemAudio?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingSaved(let id, let hooks):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meeting saved"),
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onDismissMeeting?() }, minWidth: width) {
                if hooks { Button("run hooks") { model.onRunHooks?(id) }.buttonStyle(SquareButtonStyle(kind: .quiet)) }
                Button("show") { model.onShowMeeting?(id) }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingHooksDone(let id, let ran, let failed):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text(PillView.hooksDone(ran: ran, failed: failed)), failed: failed > 0,
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onDismissMeeting?() }, minWidth: width) {
                Button("view") { model.onShowMeeting?(id) }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingTranscribeAsk(let id):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("transcribe now?"), minWidth: width) {
                Button("later") { model.onTranscribeMeeting?(id, false) }.buttonStyle(SquareButtonStyle(kind: .quiet))
                Button("okay") { model.onTranscribeMeeting?(id, true) }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingFailed(let id):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meeting not transcribed"), failed: true,
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onDismissMeeting?() }, minWidth: width) {
                Button("show") { model.onShowMeeting?(id) }.buttonStyle(SquareButtonStyle())
            }
        case .meetingDiskFull(let id):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("disk full · meeting stopped"), failed: true,
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onDismissMeeting?() }, minWidth: width) {
                Button("show") { model.onShowMeeting?(id) }.buttonStyle(SquareButtonStyle())
            }
        case .meetingFolderUnavailable:
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meetings folder unavailable"), failed: true,
                         dismiss: "dismiss", onDismiss: { model.closeNow = true; model.onDismissMeeting?() }, minWidth: width) {
                Button("settings") { model.onShowMeeting?(nil) }.buttonStyle(SquareButtonStyle())
            }
        default:
            EmptyView()
        }
    }

    /// What the pill says when the hooks run on a meeting have finished.
    nonisolated static func hooksDone(ran: Int, failed: Int) -> String {
        switch failed {
        case 0: ran == 1 ? "hook done" : "\(counted(ran, "hook")) done"
        case ran: ran == 1 ? "hook failed" : "\(counted(ran, "hook")) failed"
        default: "\(failed) of \(counted(ran, "hook")) failed"
        }
    }
}
