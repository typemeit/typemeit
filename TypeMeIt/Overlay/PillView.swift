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

/// The pill for the prompts and toasts after a dictation: 44 pt tall,
/// capsule, three columns with the label dead centre, an icon on the left,
/// the buttons on the right. Set like the rest of the design system: flat
/// paper, an ink hairline, mono lowercase labels, ink buttons, and the one
/// shadow the system allows.
struct PillView: View {
    @Bindable var model: OverlayModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            leftSlot.frame(minWidth: 24, alignment: .leading)
            Spacer(minLength: 12)
            centre
            Spacer(minLength: 12)
            rightSlot.frame(minWidth: 24, alignment: .trailing)
        }
        .padding(.leading, 16)
        .padding(.trailing, 9)
        // The design width, stretching for a long learned word up to what
        // the panel can hold, then truncating the word's middle so both
        // ends still read.
        .frame(minWidth: model.width, maxWidth: OverlayPanel.size.width - 40)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 44)
        .background(Capsule().fill(DesignTokens.Colors.paper))
        .overlay(Capsule().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
        .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.14), radius: 14, y: 10)
        .animation(.spring(duration: 0.46, bounce: 0.1), value: model.width)
        .onHover { model.toastPaused = $0 }
    }

    // MARK: Slots

    @ViewBuilder private var leftSlot: some View {
        switch model.state {
        case .copyPrompt:
            Image("akar-clipboard").resizable().frame(width: 14, height: 14).foregroundStyle(DesignTokens.Colors.ink2)
        case .learned:
            // The same mark the intelligence page puts beside a learned word, and
            // a way to that page.
            Button { model.onOpenIntelligence?() } label: {
                Image("akar-sparkles").resizable().frame(width: 14, height: 14)
            }
            .buttonStyle(QuietButtonStyle(side: 24, radius: DesignTokens.Radius.full))
            .help("Open intelligence")
        case .updateReady, .updateFailed:
            Image("akar-sparkles").resizable().frame(width: 14, height: 14).foregroundStyle(DesignTokens.Colors.ink)
        case .meetingPrompt(let app), .meetingNeverAsking(let app), .meetingResumed(let app):
            Image(nsImage: PillView.icon(for: app)).resizable().frame(width: 18, height: 18)
        case .meetingSystemAudioOff:
            Image("akar-microphone").resizable().frame(width: 14, height: 14).foregroundStyle(DesignTokens.Colors.ink2)
        case .meetingSaved, .meetingTranscribeAsk, .meetingFailed, .meetingDiskFull, .meetingFolderUnavailable:
            Image("akar-people-group").resizable().frame(width: 14, height: 14).foregroundStyle(DesignTokens.Colors.ink2)
        default:
            Color.clear.frame(width: 24, height: 24)
        }
    }

    /// The app's own icon, or the generic one for a daemon or web content.
    static func icon(for app: ProcessOwner.Owner) -> NSImage {
        if let url = app.appURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .applicationBundle)
    }

    @ViewBuilder private var centre: some View {
        switch model.state {
        case .copyPrompt(let cantType):
            label(cantType ? "accessibility is off, so it can't type" : "nowhere to type it")
        case .learned(_, let words):
            if words.count == 1 {
                // The word itself in bold, kept as the user spelt it, since
                // that spelling is what was added.
                label(Text("added ") + Text(words[0]).bold() + Text(" to dictionary"))
            } else {
                label("learned \(counted(words.count, "word"))")
            }
        case .undone:
            label("undone")
        case .updateReady(let v):
            label(Text("version ") + Text(v).bold() + Text(" is ready"))
        case .updateFailed(let v):
            label("version \(v) didn't download")
        case .meetingPrompt:
            label("record this meeting?")
        case .meetingNeverAsking(let app):
            label("won't ask for \(app.name.lowercased()) again")
        case .meetingSystemAudioOff:
            label("system audio is off")
        case .meetingSaved:
            label("meeting saved")
        case .meetingTranscribeAsk:
            label("transcribe now?")
        case .meetingFailed:
            label("meeting not transcribed")
        case .meetingDiskFull:
            label("disk full · meeting stopped")
        case .meetingResumed(let app):
            label("recording again · \(app.name.lowercased())")
        case .meetingFolderUnavailable:
            label("meetings folder unavailable")
        default:
            EmptyView()
        }
    }

    private func label(_ text: String) -> some View {
        label(Text(text))
    }

    private func label(_ text: Text) -> some View {
        text.font(.system(size: 12, design: .monospaced)).foregroundStyle(DesignTokens.Colors.ink2).lineLimit(1).truncationMode(.middle)
    }

    @ViewBuilder private var rightSlot: some View {
        switch model.state {
        case .copyPrompt(let cantType):
            HStack(spacing: 6) {
                if cantType {
                    Button("system settings") { model.onOpenAccessibility?() }.buttonStyle(InkButtonStyle())
                }
                // Sized for "copy transcript" from the start, so the button
                // does not shrink when the label changes.
                Button { model.onCopy?() } label: { Text(model.copied ? "copied" : "copy transcript").frame(minWidth: 110) }
                    .buttonStyle(InkButtonStyle(primary: true)).disabled(model.copied)
                cross(help: "Cancel") { model.onCancel?() }
            }
        case .learned:
            HStack(spacing: 6) {
                Button("undo") { model.onUndo?() }.buttonStyle(InkButtonStyle())
                cross(help: "Dismiss") { model.onKeep?() }
            }
        case .updateReady:
            HStack(spacing: 6) {
                Button("install") { model.onInstall?() }.buttonStyle(InkButtonStyle(primary: true))
                cross(help: "Later") { model.onKeep?() }
            }
        case .updateFailed:
            cross(help: "Dismiss") { model.onKeep?() }
        case .meetingPrompt:
            HStack(spacing: 6) {
                Button("record") { model.onRecordMeeting?() }.buttonStyle(InkButtonStyle(primary: true))
                cross(help: "Not now") { model.onDeclineMeeting?() }
            }
        case .meetingNeverAsking:
            HStack(spacing: 6) {
                Button("undo") { model.onUndoNeverAsk?() }.buttonStyle(InkButtonStyle())
                cross(help: "Dismiss") { model.onDismissMeeting?() }
            }
        case .meetingSystemAudioOff:
            HStack(spacing: 6) {
                Button("system settings") { model.onOpenSystemAudio?() }.buttonStyle(InkButtonStyle(primary: true))
                cross(help: "Dismiss") { model.onDismissMeeting?() }
            }
        case .meetingSaved(let id), .meetingDiskFull(let id):
            HStack(spacing: 6) {
                Button("show") { model.onShowMeeting?(id) }.buttonStyle(InkButtonStyle(primary: true))
                cross(help: "Dismiss") { model.onDismissMeeting?() }
            }
        case .meetingTranscribeAsk(let id):
            HStack(spacing: 6) {
                Button("later") { model.onTranscribeMeeting?(id, false) }.buttonStyle(InkButtonStyle())
                Button("okay") { model.onTranscribeMeeting?(id, true) }.buttonStyle(InkButtonStyle(primary: true))
            }
        case .meetingFailed(let id):
            HStack(spacing: 6) {
                Button("show") { model.onShowMeeting?(id) }.buttonStyle(InkButtonStyle())
                cross(help: "Dismiss") { model.onDismissMeeting?() }
            }
        case .meetingResumed:
            HStack(spacing: 6) {
                Button("stop") { model.onStopMeeting?() }.buttonStyle(InkButtonStyle(primary: true))
                cross(help: "Dismiss") { model.onDismissMeeting?() }
            }
        case .meetingFolderUnavailable:
            HStack(spacing: 6) {
                Button("settings") { model.onShowMeeting?(nil) }.buttonStyle(InkButtonStyle(primary: true))
                cross(help: "Dismiss") { model.onDismissMeeting?() }
            }
        default:
            Color.clear.frame(width: 22, height: 22)
        }
    }

    /// The quiet dismiss: a cross with no outline, ink-2 until hovered. Round,
    /// since the wash sits inside a capsule.
    private func cross(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image("akar-cross").resizable().frame(width: 10, height: 10)
        }
        .buttonStyle(QuietButtonStyle(side: 26, radius: DesignTokens.Radius.full))
        .help(help)
    }
}
