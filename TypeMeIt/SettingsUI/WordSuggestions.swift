import SwiftUI

/// The dictionary's word check: Claude reads past dictations, newest first,
/// for words the speech model likely misheard. A heading with "check words"
/// (or, while a run reads, how many dictations it has and stop), then each
/// change found with where it was heard, a fix that applies it and a cross
/// that turns it down.
struct WordSuggestions: View {
    @State private var check = WordCheck.shared
    @State private var store = Store.shared

    var body: some View {
        let history = store.history
        let groups = check.groups(in: history)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("misheard words").foregroundStyle(DesignTokens.Colors.ink3)
                if !groups.isEmpty { Text(groups.count.formatted()).foregroundStyle(DesignTokens.Colors.ink).monospacedDigit() }
                Spacer(minLength: 0)
                button(history)
            }
            .font(Square.mono(11))
            .padding(.bottom, 8)
            if case .failed(let text) = check.status { SquareFailure(text: text).lineLimit(2).padding(.bottom, 8) }
            ForEach(groups) { group in
                WordSuggestionRow(group: group, entries: Dictionary(history.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
                                  open: open, fix: { check.approve(group) }, dismiss: { check.dismiss(group) })
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { SquareRule() }
        .padding(.top, 16)
    }

    @ViewBuilder private func button(_ history: [HistoryEntry]) -> some View {
        switch check.status {
        case .checking(let n):
            HStack(spacing: 8) {
                SquareClaudeSpinner()
                    .foregroundStyle(DesignTokens.Colors.claude)
                Text("checking \(counted(n, "dictation"))…")
                    .foregroundStyle(DesignTokens.Colors.ink2)
                Button("stop") { check.stop() }.buttonStyle(SquareButtonStyle(kind: .quiet))
            }
        default:
            let newestFirst = Array(history.reversed())
            let left = check.unchecked(newestFirst).count
            SquareClaudeButton(title: "check words") { check.check(newestFirst) }
                .disabled(left == 0 || check.status == .stopping)
                .help(left == 0 ? "all checked" : "claude reads the newest unchecked dictations · \(left.formatted()) left")
        }
    }

    /// Shows the dictation on its own page.
    private func open(_ id: UUID) {
        AppState.shared.revealDictation = id
        AppState.shared.settingsTab = .history
    }
}

/// One word: each spelling it was heard as struck through in red, the word
/// in green, a tag when it joins the dictionary, then fix and dismiss. Under
/// it, each place it was heard: a play button for the moment around it when
/// the audio was kept, and the dictation's words either side, which open the
/// dictation. Hovering says why.
private struct WordSuggestionRow: View {
    let group: WordCheck.Group
    let entries: [UUID: HistoryEntry]
    let open: (UUID) -> Void
    let fix: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false
    @State private var player = RecordingPlayer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: SquareListColumns.gap) {
                HStack(spacing: 6) {
                    ForEach(group.heard, id: \.self) { heard in
                        Text(heard).strikethrough().foregroundStyle(DesignTokens.Colors.diffRemove)
                    }
                    Text("→").foregroundStyle(DesignTokens.Colors.ink3)
                    Text(group.meant).foregroundStyle(DesignTokens.Colors.diffAdd)
                }
                .font(Square.mono(12))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if group.term { SquareTag(text: "new word") }
                HStack(spacing: 4) {
                    Button("fix", action: fix).buttonStyle(SquareButtonStyle())
                    Button(action: dismiss) { SquareIcon("akar-cross", size: 10) }
                        .buttonStyle(SquareIconButtonStyle())
                        .help("dismiss")
                        .accessibilityLabel("dismiss")
                }
            }
            ForEach(Array(group.changes.enumerated()), id: \.offset) { _, change in
                if let entry = entries[change.dictation] { place(change, entry) }
            }
        }
        .padding(.horizontal, SquareListColumns.inset)
        .padding(.vertical, 7)
        .background(hovering ? DesignTokens.Colors.inkA04 : .clear)
        .overlay(alignment: .top) { SquareRule() }
        .onHover { hovering = $0 }
        .help(group.why)
    }

    private func place(_ change: WordCheck.Change, _ entry: HistoryEntry) -> some View {
        HStack(spacing: 6) {
            ZStack { playButton(change, entry) }.frame(width: SquareButtonStyle.height)
            Button { open(entry.id) } label: {
                excerpt(change, entry.displayText)
                    .font(Square.sans(13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("open dictation")
        }
    }

    /// Plays the seconds around where the heard words fall in the
    /// dictation, placed by how far into its text they are.
    @ViewBuilder private func playButton(_ change: WordCheck.Change, _ entry: HistoryEntry) -> some View {
        if let file = entry.recordingFile, let seconds = entry.durationMs.map({ Double($0) / 1000 }),
           let clip = WordCheck.clip(of: change.heard, in: entry.displayText, seconds: seconds) {
            let on = player.playing == entry.id && !player.paused
            Button {
                if on { player.pause() } else {
                    player.play(id: entry.id, urls: [RecordingArchive.url(for: file)], from: clip.lowerBound, until: clip.upperBound)
                }
            } label: { SquareIcon(on ? "akar-stop" : "akar-play", size: 12) }
                .buttonStyle(SquareIconButtonStyle())
                .help(on ? "stop" : "play")
                .accessibilityLabel(on ? "stop" : "play")
        }
    }

    /// The dictation's words either side, the heard words struck through in
    /// red and what replaces them in green.
    private func excerpt(_ change: WordCheck.Change, _ text: String) -> Text {
        guard let parts = WordCheck.excerpt(of: text, around: change.heard) else { return Text(text).foregroundStyle(DesignTokens.Colors.ink2) }
        let before = Text(parts.before).foregroundStyle(DesignTokens.Colors.ink3)
        let heard = Text(change.heard).strikethrough().foregroundStyle(DesignTokens.Colors.diffRemove)
        let meant = Text(group.meant).foregroundStyle(DesignTokens.Colors.diffAdd)
        let after = Text(parts.after).foregroundStyle(DesignTokens.Colors.ink3)
        return Text("\(before)\(heard) \(meant)\(after)")
    }
}
