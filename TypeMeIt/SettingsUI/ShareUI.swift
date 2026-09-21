import SwiftUI

/// The code, in fours, with the copy that saves reading it out.
private struct CodePlate: View {
    let code: String

    var body: some View {
        HStack(spacing: 8) {
            Text(ShareCode.spaced(code))
                .font(.system(size: 18, design: .monospaced))
                .foregroundStyle(DesignTokens.Colors.ink)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Rectangle().fill(DesignTokens.Colors.inkA04))
                .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
                .textSelection(.enabled)
            Button { Output.copyToClipboard(ShareCode.spaced(code)) } label: {
                Image("akar-copy").resizable().frame(width: 14, height: 14)
            }
            .buttonStyle(QuietButtonStyle(side: 24)).help("copy")
        }
    }
}

/// The name the other end sees this Mac called. It only lands when the field
/// is left or Return is pressed.
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
        let name = Sharing.clean(text)
        text = name
        guard name != settings.shareName else { return }
        settings.shareName = name
    }
}

/// The notes a share sheet is up for. A sheet is presented from a value
/// rather than a flag so the set it is sealing cannot change under it.
struct ShareDraft: Identifiable {
    let id = UUID()
    let notes: [SharedNote]
}

/// Seals the notes, leaves them, and shows the code. Put up as a sheet from
/// the history tab.
struct ShareSheet: View {
    let notes: [SharedNote]
    let done: () -> Void

    @State private var sharing = Sharing.shared
    @State private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("share \(counted(notes.count, "note"))")
                .font(DesignTokens.Fonts.heading)
            if !settings.sharing {
                off
            } else if let outgoing = sharing.outgoing {
                sending(outgoing)
            } else {
                Text("sealing…").font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
            }
            HStack {
                Spacer()
                Button("done") { sharing.outgoing?.cancel(); sharing.outgoing = nil; done() }
                    .buttonStyle(InkButtonStyle())
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(DesignTokens.Colors.paper)
        .onAppear { if settings.sharing, sharing.outgoing == nil { sharing.offer(notes) } }
    }

    @ViewBuilder
    private var off: some View {
        Text("sharing is off.")
            .font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
        Button("turn on sharing") { settings.sharing = true; sharing.offer(notes) }
            .buttonStyle(InkButtonStyle(primary: true))
    }

    @ViewBuilder
    private func sending(_ outgoing: OutgoingShare) -> some View {
        switch outgoing.stage {
        case .sealing:
            Text("sealing…").font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
        case .ready(let code):
            CodePlate(code: code)
            Text("hand this over however you like. it opens once, and it is gone in ten minutes.")
                .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink2)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let reason):
            Text(reason)
                .font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.diffRemove)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Where a code is typed in, and where what it opens is shown. Nothing here
/// is written to disk: closing it is the end of the notes unless they were
/// copied out.
struct ShareInbox: View {
    @State private var sharing = Sharing.shared
    @State private var typed = ""
    @State private var wrong = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let incoming = sharing.incoming {
                content(incoming)
            } else {
                entry
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(DesignTokens.Colors.paper)
        .onDisappear {
            sharing.incoming?.dismiss()
            sharing.incoming = nil
        }
    }

    @ViewBuilder
    private var entry: some View {
        Text("receive a note").font(DesignTokens.Fonts.heading)
        Text("paste the code you were given.")
            .font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.ink2)
        TextField("", text: $typed)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 15, design: .monospaced))
            .onSubmit { go() }
            .onChange(of: typed) { _, _ in wrong = false }
        if wrong {
            Text("that is not a code").font(.system(size: 11)).foregroundStyle(DesignTokens.Colors.diffRemove)
        }
        HStack {
            Spacer()
            Button("close") { dismiss() }.buttonStyle(InkButtonStyle())
            Button("go") { go() }
                .buttonStyle(InkButtonStyle(primary: true))
                .disabled(typed.isEmpty)
        }
    }

    private func go() {
        if sharing.receive(typed) { typed = "" } else { wrong = true }
    }

    @ViewBuilder
    private func content(_ incoming: IncomingShare) -> some View {
        switch incoming.stage {
        case .fetching:
            Text("collecting…").font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.ink2)
        case .arrived(let from, let notes):
            Text("\(counted(notes.count, "note")) from \(from)")
                .font(DesignTokens.Fonts.heading).fixedSize(horizontal: false, vertical: true)
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
                Button("close") { dismiss() }.buttonStyle(InkButtonStyle(primary: true))
            }
        case .failed(let reason):
            Text(reason).font(.system(size: 13)).foregroundStyle(DesignTokens.Colors.diffRemove)
                .fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("try another code") { back() }.buttonStyle(InkButtonStyle()) }
        }
    }

    /// Back to the code field, ready for another go.
    private func back() {
        sharing.incoming?.dismiss()
        sharing.incoming = nil
    }
}
