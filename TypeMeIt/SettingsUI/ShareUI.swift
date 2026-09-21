import SwiftUI

/// The four digits, spaced out and monospaced so they can be read down a
/// phone line without being misheard.
private struct ShareCode: View {
    let code: String

    var body: some View {
        Text(code.map { String($0) }.joined(separator: " "))
            .font(.system(size: 28, design: .monospaced))
            .foregroundStyle(DesignTokens.Colors.ink)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Rectangle().fill(DesignTokens.Colors.inkA04))
            .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
            .textSelection(.enabled)
    }
}

/// The name this Mac is listed under. It only lands when the field is left
/// or Return is pressed: writing it as it is typed would put the network
/// listener up and down again a letter at a time.
struct ShareNameField: View {
    @State private var settings = Settings.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
            .focused($focused)
            .onAppear { text = settings.shareName }
            .onSubmit { commit() }
            .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        let name = IncomingShare.clean(text)
        text = name
        guard name != settings.shareName else { return }
        settings.shareName = name
    }
}

/// The notes a share sheet is up for. A sheet is presented from a value
/// rather than a flag so the set it is offering cannot change under it while
/// the user picks who to send to.
struct ShareDraft: Identifiable {
    let id = UUID()
    let notes: [SharedNote]
}

/// Picks the Mac to send to, then shows how the sending went. Put up as a
/// sheet from the history tab.
struct ShareSheet: View {
    let notes: [SharedNote]
    let done: () -> Void

    @State private var sharing = Sharing.shared
    @State private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("share \(counted(notes.count, "note"))")
                .font(DesignTokens.Fonts.heading)
            if let outgoing = sharing.outgoing {
                sending(outgoing)
            } else if !settings.sharing {
                off
            } else {
                picker
            }
            HStack {
                Spacer()
                Button(closeLabel) { sharing.outgoing?.cancel(); sharing.outgoing = nil; done() }
                    .buttonStyle(InkButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(DesignTokens.Colors.paper)
    }

    private var closeLabel: String {
        guard let stage = sharing.outgoing?.stage else { return "close" }
        return switch stage {
        case .reaching, .waiting: "cancel"
        case .sent, .declined, .failed: "close"
        }
    }

    @ViewBuilder
    private var off: some View {
        Text("sharing is off. turning it on lists this mac on the network you are on.")
            .font(.system(size: 12)).foregroundStyle(DesignTokens.Colors.ink2)
            .fixedSize(horizontal: false, vertical: true)
        Button("turn on sharing") { settings.sharing = true }
            .buttonStyle(InkButtonStyle(primary: true))
    }

    @ViewBuilder
    private var picker: some View {
        if sharing.peers.isEmpty {
            Text("no one nearby")
                .font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
            Text("the other mac needs type me it open, sharing on, and the same network.")
                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink3)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SettingsGroup {
                ForEach(Array(sharing.peers.enumerated()), id: \.element.id) { i, peer in
                    Button { sharing.send(notes, to: peer) } label: {
                        HStack {
                            Text(peer.name).font(DesignTokens.Fonts.ui.monospaced())
                            Spacer()
                            Image("akar-chevron-down").resizable().frame(width: 10, height: 10)
                                .rotationEffect(.degrees(-90))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(QuietButtonStyle(radius: 0))
                    if i < sharing.peers.count - 1 { RowRule() }
                }
            }
        }
    }

    @ViewBuilder
    private func sending(_ outgoing: OutgoingShare) -> some View {
        switch outgoing.stage {
        case .reaching:
            Text("reaching \(outgoing.peer.name)…")
                .font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
        case .waiting(let code):
            ShareCode(code: code)
            Text("read this out. \(outgoing.peer.name) sees the same four digits, and the notes go once they say yes.")
                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
        case .sent:
            Text("sent to \(outgoing.peer.name)")
                .font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink)
        case .declined:
            Text("\(outgoing.peer.name) said no")
                .font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
        case .failed(let reason):
            Text(reason)
                .font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.diffRemove)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The window another Mac's offer opens. It asks, and then it shows what
/// arrived. Nothing here is written to disk: closing it is the end of the
/// notes unless they were copied out.
struct ShareInbox: View {
    @State private var sharing = Sharing.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let incoming = sharing.incoming {
                content(incoming)
            } else {
                Text("nothing waiting").font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
                HStack { Spacer(); Button("close") { dismiss() }.buttonStyle(InkButtonStyle()) }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(DesignTokens.Colors.paper)
        // The window's own close button gets here too. Without this an
        // offer left half-answered would sit in `incoming` and turn away
        // every Mac that called afterwards.
        .onDisappear {
            sharing.incoming?.dismiss()
            sharing.incoming = nil
        }
    }

    @ViewBuilder
    private func content(_ incoming: IncomingShare) -> some View {
        switch incoming.stage {
        case .greeting:
            Text("a mac is calling…").font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
        case .asking(let from, let code, let count):
            Text("\(from) wants to send you \(counted(count, "note"))")
                .font(DesignTokens.Fonts.heading).fixedSize(horizontal: false, vertical: true)
            ShareCode(code: code)
            Text("say yes only if the same four digits are on their screen.")
                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink2)
            HStack {
                Spacer()
                Button("no thanks") { incoming.decline(); close() }.buttonStyle(InkButtonStyle())
                Button("accept") { incoming.accept() }.buttonStyle(InkButtonStyle(primary: true))
            }
        case .opening:
            Text("opening…").font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
        case .arrived(let notes):
            Text(counted(notes.count, "note")).font(DesignTokens.Fonts.heading)
            ScrollView {
                SettingsGroup {
                    ForEach(Array(notes.enumerated()), id: \.element.id) { i, note in
                        HStack(alignment: .top, spacing: 12) {
                            Text(note.text).font(.system(size: 13)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { Output.copyToClipboard(note.text) } label: {
                                Image("akar-copy").resizable().frame(width: 14, height: 14)
                            }
                            .buttonStyle(QuietButtonStyle(side: 24)).help("copy")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        if i < notes.count - 1 { RowRule() }
                    }
                }
            }
            .frame(maxHeight: 260)
            Text("not kept. copy what you want before closing.")
                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink3)
            HStack {
                Spacer()
                Button("copy all") { Output.copyToClipboard(notes.map(\.text).joined(separator: "\n\n")) }
                    .buttonStyle(InkButtonStyle())
                Button("close") { close() }.buttonStyle(InkButtonStyle(primary: true))
            }
        case .failed(let reason):
            Text(reason).font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.diffRemove)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("close") { close() }.buttonStyle(InkButtonStyle()) }
        }
    }

    private func close() {
        dismiss()
    }
}
