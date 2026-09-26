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
        let width = model.width
        switch model.state {
        case .copyPrompt(let cantType):
            SquarePrompt(mark: .icon("akar-clipboard"), message: Text(cantType ? "accessibility is off, so it can't type" : "nowhere to type it"),
                         dismiss: "cancel", onDismiss: { model.onCancel?() }, minWidth: width) {
                if cantType {
                    Button("system settings") { model.onOpenAccessibility?() }.buttonStyle(SquareButtonStyle())
                }
                // Sized for "copy transcript" from the start, so the button
                // does not shrink when the label changes.
                Button { model.onCopy?() } label: { Text(model.copied ? "copied" : "copy transcript").frame(minWidth: 110) }
                    .buttonStyle(SquareButtonStyle(kind: .primary))
                    .disabled(model.copied)
            }
        case .learned(_, let words):
            // The word itself in medium, kept as the user spelt it, since that
            // spelling is what was added.
            SquarePrompt(mark: .button("akar-sparkles", help: "open dictionary") { model.onOpenDictionary?() },
                         message: words.count == 1 ? Text("added \(Text(words[0]).fontWeight(.medium)) to dictionary") : Text("learned \(counted(words.count, "word"))"),
                         dismiss: "dismiss", onDismiss: { model.onKeep?() }, minWidth: width) {
                Button("undo") { model.onUndo?() }.buttonStyle(SquareButtonStyle())
            }
        case .undone:
            SquarePrompt(message: Text("undone"), minWidth: width) {}
        case .updateReady(let v):
            SquarePrompt(mark: .icon("akar-sparkles"), message: Text("version \(Text(v).fontWeight(.medium)) is ready"),
                         dismiss: "later", onDismiss: { model.onKeep?() }, minWidth: width) {
                Button("install") { model.onInstall?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .updateFailed(let v):
            SquarePrompt(mark: .icon("akar-sparkles"), message: Text("version \(v) didn't download"), failed: true,
                         dismiss: "dismiss", onDismiss: { model.onKeep?() }, minWidth: width) {}
        case .meetingPrompt(let app):
            SquarePrompt(mark: .app(PillView.letter(app)), message: Text("record this meeting?"),
                         dismiss: "not now", onDismiss: { model.onDeclineMeeting?() }, minWidth: width) {
                Button("record") { model.onRecordMeeting?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingResumed(let app):
            SquarePrompt(mark: .app(PillView.letter(app)), message: Text("recording again · \(app.name.lowercased())"),
                         dismiss: "dismiss", onDismiss: { model.onDismissMeeting?() }, minWidth: width) {
                Button("stop") { model.onStopMeeting?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingSystemAudioOff:
            SquarePrompt(mark: .icon("akar-microphone"), message: Text("system audio is off"),
                         dismiss: "dismiss", onDismiss: { model.onDismissMeeting?() }, minWidth: width) {
                Button("system settings") { model.onOpenSystemAudio?() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingSaved(let id):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meeting saved"),
                         dismiss: "dismiss", onDismiss: { model.onDismissMeeting?() }, minWidth: width) {
                Button("show") { model.onShowMeeting?(id) }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingTranscribeAsk(let id):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("transcribe now?"), minWidth: width) {
                Button("later") { model.onTranscribeMeeting?(id, false) }.buttonStyle(SquareButtonStyle())
                Button("okay") { model.onTranscribeMeeting?(id, true) }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .meetingFailed(let id):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meeting not transcribed"), failed: true,
                         dismiss: "dismiss", onDismiss: { model.onDismissMeeting?() }, minWidth: width) {
                Button("show") { model.onShowMeeting?(id) }.buttonStyle(SquareButtonStyle())
            }
        case .meetingDiskFull(let id):
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("disk full · meeting stopped"), failed: true,
                         dismiss: "dismiss", onDismiss: { model.onDismissMeeting?() }, minWidth: width) {
                Button("show") { model.onShowMeeting?(id) }.buttonStyle(SquareButtonStyle())
            }
        case .meetingFolderUnavailable:
            SquarePrompt(mark: .icon("akar-people-group"), message: Text("meetings folder unavailable"), failed: true,
                         dismiss: "dismiss", onDismiss: { model.onDismissMeeting?() }, minWidth: width) {
                Button("settings") { model.onShowMeeting?(nil) }.buttonStyle(SquareButtonStyle())
            }
        default:
            EmptyView()
        }
    }

    /// The app a call is in, as the one letter the prompt's mark shows.
    static func letter(_ app: ProcessOwner.Owner) -> String {
        app.name.lowercased().first.map(String.init) ?? "·"
    }
}
