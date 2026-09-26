import SwiftUI

/// A dictation on its own page: what was typed, what was heard and how the
/// clean-up changed it word by word, where and how long, the timings, and its
/// audio when that was kept. Any word of what was heard can be kept as a
/// custom word or given the spelling it should have had.
struct DictationPage: View {
    let entry: HistoryEntry
    let back: () -> Void
    @State private var store = Store.shared
    @State private var player = RecordingPlayer.shared
    @State private var heardOpen = true
    @State private var copied = false
    @State private var deleting = false

    private static let railWidth: CGFloat = 272

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 0) {
                ScrollView { article }.frame(maxWidth: .infinity)
                rail
            }
            .frame(maxHeight: .infinity)
            if let file = entry.recordingFile {
                DictationPlayer(entry: entry, url: RecordingArchive.url(for: file))
            } else {
                Text("no audio kept")
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .padding(.vertical, 14)
                    .padding(.horizontal, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { SquareRule() }
            }
        }
        // Playback belongs to the page: leaving it stops it.
        .onDisappear { if player.playing == entry.id { player.stop() } }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                Label {
                    Text("history")
                } icon: {
                    SquareIcon("akar-chevron-down", size: 10).rotationEffect(.degrees(90))
                }
            }
            .buttonStyle(SquareButtonStyle(kind: .quiet))
            .keyboardShortcut(.cancelAction)
            Spacer(minLength: 0)
            Button {
                Output.copyToClipboard(entry.displayText)
                copied = true
            } label: {
                SquareIcon(copied ? "akar-check" : "akar-copy", size: copied ? 12 : 14)
            }
            .buttonStyle(SquareIconButtonStyle())
            .help("copy")
            .accessibilityLabel("copy")
            Button { deleting.toggle() } label: { SquareIcon("akar-trash-can", size: 14) }
                .buttonStyle(SquareIconButtonStyle())
                .help("delete")
                .accessibilityLabel("delete")
                .squarePopover(isPresented: $deleting) { deleteConfirm }
        }
        .padding(.top, 12)
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { SquareRule() }
    }

    /// While the audio is kept, it can go on its own and the text stay.
    private var deleteConfirm: some View {
        let audio = entry.recordingFile != nil
        return SquareConfirm(title: "delete this dictation?",
                             detail: audio ? "it has \(DictationPage.length(entry.durationMs ?? 0)) of audio." : nil,
                             width: 300) {
            Button("cancel") { deleting = false }.buttonStyle(SquareButtonStyle())
            if audio {
                Button("audio only") {
                    if player.playing == entry.id { player.stop() }
                    store.deleteAudio(id: entry.id)
                    deleting = false
                }
                .buttonStyle(SquareButtonStyle())
            }
            Button(audio ? "everything" : "delete") {
                if player.playing == entry.id { player.stop() }
                deleting = false
                store.delete(id: entry.id)
                back()
            }
            .buttonStyle(SquareButtonStyle(kind: .primary))
        }
    }

    private var article: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(dateLine)
                .font(Square.mono(12))
                .foregroundStyle(DesignTokens.Colors.ink2)
            Text(entry.displayText)
                .font(Square.sans(22))
                .lineSpacing(6)
                .foregroundStyle(DesignTokens.Colors.ink)
                .textSelection(.enabled)
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.top, 14)
            heard.padding(.top, 28)
        }
        .padding(.top, 26)
        .padding(.leading, 44)
        .padding(.trailing, 40)
        .padding(.bottom, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the speech model heard, against what was typed.
    private var heard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { heardOpen.toggle() } label: {
                HStack(spacing: 5) {
                    SquareIcon("akar-chevron-down", size: 10).rotationEffect(.degrees(heardOpen ? 0 : -90))
                    Text("heard")
                    CharDelta(heard: entry.transcript, typed: entry.displayText)
                }
                .font(Square.mono(10))
                .foregroundStyle(DesignTokens.Colors.ink2)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(heardOpen ? "hide what was heard" : "show what was heard before clean-up")
            if heardOpen {
                TranscriptDiff(heard: entry.transcript, typed: entry.displayText)
                    .padding(.top, 2)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.Colors.inkA04)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            SquareSubhead(text: "where", first: true)
            Text(whereLine)
                .font(Square.mono(12))
                .foregroundStyle(DesignTokens.Colors.ink)
                .lineLimit(3)
            SquareSubhead(text: "length")
            Text(lengthLine)
                .font(Square.mono(12))
                .foregroundStyle(DesignTokens.Colors.ink)
            SquareSubhead(text: "timings")
            VStack(spacing: 0) {
                ForEach(timings, id: \.key) { timing in
                    HStack {
                        Text(timing.key).foregroundStyle(DesignTokens.Colors.ink3)
                        Spacer(minLength: 12)
                        Text(timing.value).foregroundStyle(DesignTokens.Colors.ink)
                    }
                    .font(Square.mono(11))
                    .monospacedDigit()
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { SquareRule() }
                }
            }
            .overlay(alignment: .bottom) { SquareRule() }
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 22)
        .frame(width: DictationPage.railWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .leading) { Rectangle().fill(DesignTokens.Colors.rule).frame(width: DesignTokens.hairline) }
    }

    /// "wednesday 23 september · 14:21".
    private var dateLine: String {
        let day = entry.timestamp.formatted(.dateTime.weekday(.wide).day().month(.wide)).lowercased()
        return "\(day) · \(entry.timestamp.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))"
    }

    private var whereLine: String {
        let app = HistoryTab.app(of: entry)
        guard let title = entry.windowTitle, !title.isEmpty else { return app }
        return "\(app) · \(title)"
    }

    private var lengthLine: String {
        let words = counted(HistoryTab.words(in: entry), "word")
        guard let ms = entry.durationMs else { return words }
        return "\(DictationPage.length(ms)) · \(words)"
    }

    /// The speech model's time and its real-time factor, clean-up's time and
    /// whether its text was used, and the two together.
    private var timings: [(key: String, value: String)] {
        let e = entry
        var rows: [(key: String, value: String)] = [("asr", e.transcribeMs.map { "\($0)ms" } ?? "n/a")]
        if let ms = e.transcribeMs, let audio = e.durationMs, audio > 0 {
            rows.append(("rtf", String(format: "%.2fx", Double(ms) / Double(audio))))
        }
        if e.postProcessRequested {
            let outcome = e.postProcessMs == nil ? "" : (e.postProcessed == nil ? " →fallback" : " →applied")
            rows.append(("llm", (e.postProcessMs.map { "\($0)ms" } ?? "n/a") + outcome))
        } else {
            rows.append(("llm", "off"))
        }
        rows.append(("total", e.transcribeMs.map { "\($0 + (e.postProcessMs ?? 0))ms" } ?? "n/a"))
        return rows
    }

    /// "5s", or "1m 05s" past a minute.
    static func length(_ ms: Int) -> String {
        let seconds = Int((Double(ms) / 1000).rounded())
        guard seconds >= 60 else { return "\(seconds)s" }
        return String(format: "%dm %02ds", seconds / 60, seconds % 60)
    }
}

/// Play or pause on the slab, where it is along a bar to click or drag, and
/// the time over the length.
private struct DictationPlayer: View {
    let entry: HistoryEntry
    let url: URL
    @State private var player = RecordingPlayer.shared

    var body: some View {
        let loaded = player.playing == entry.id
        let running = loaded && !player.paused
        let total = loaded ? player.duration : Double(entry.durationMs ?? 0) / 1000
        // Ticks only while playing: each tick lays the bar out again.
        TimelineView(.animation(minimumInterval: 0.1, paused: !running)) { _ in
            let at = loaded ? player.currentTime : 0
            HStack(spacing: 18) {
                Button {
                    if running { player.pause() } else { player.play(id: entry.id, urls: [url]) }
                } label: {
                    SquareIcon(running ? "akar-pause" : "akar-play", size: 14)
                }
                .buttonStyle(SquarePlayButtonStyle())
                .help(running ? "pause" : "play the audio")
                .accessibilityLabel(running ? "pause" : "play the audio")
                SquareScrubber(fraction: total > 0 ? at / total : 0) { fraction in
                    if loaded { player.seek(to: fraction * total) } else { player.play(id: entry.id, urls: [url], from: fraction * total) }
                }
                HStack(spacing: 0) {
                    Text(SquareScrubber.clock(at))
                    Text(" / \(SquareScrubber.clock(total))").foregroundStyle(DesignTokens.Colors.ink3)
                }
                .font(Square.mono(12))
                .monospacedDigit()
            }
        }
        .padding(.top, 14)
        .padding(.leading, 20)
        .padding(.trailing, 24)
        .padding(.bottom, 16)
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.ink) }
    }
}

/// The player's play button: a 34 pt square on the slab, casting a button's
/// shadow under the pointer.
struct SquarePlayButtonStyle: ButtonStyle {
    static let side: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        SquarePlayButton(configuration: configuration)
    }
}

private struct SquarePlayButton: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .foregroundStyle(DesignTokens.Colors.onSlab)
            .frame(width: SquarePlayButtonStyle.side, height: SquarePlayButtonStyle.side)
            .background(DesignTokens.Colors.slab)
            .squarePress(hot: hovering, down: configuration.isPressed, shadow: DesignTokens.Colors.ink)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// How far through the audio: ink along an ink-a04 bar. A click or a drag
/// moves it, and the player is told once, when the pointer lifts.
struct SquareScrubber: View {
    let fraction: Double
    let seek: (Double) -> Void
    @State private var dragging: Double?

    private static let height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let shown = min(max(dragging ?? fraction, 0), 1)
            Rectangle()
                .fill(DesignTokens.Colors.inkA04)
                .overlay(alignment: .leading) {
                    Rectangle().fill(DesignTokens.Colors.ink).frame(width: geo.size.width * shown)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { dragging = min(max($0.location.x / max(geo.size.width, 1), 0), 1) }
                    .onEnded { _ in
                        if let dragging { seek(dragging) }
                        dragging = nil
                    })
        }
        .frame(height: SquareScrubber.height)
        .accessibilityElement()
        .accessibilityLabel("position")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    /// "0:03", "12:04", "1:02:10".
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// How many characters the clean-up put in and took out, `+12 −3`, in the
/// diff colours, not counting spaces. Nothing when the text was left as heard.
private struct CharDelta: View {
    let heard: String
    let typed: String

    var body: some View {
        let diff = typed.filter { !$0.isWhitespace }.difference(from: heard.filter { !$0.isWhitespace })
        let (added, removed) = (diff.insertions.count, diff.removals.count)
        if added > 0 { Text("+\(added.formatted())").foregroundStyle(DesignTokens.Colors.diffAdd) }
        if removed > 0 { Text("−\(removed.formatted())").foregroundStyle(DesignTokens.Colors.diffRemove) }
    }
}

/// What was heard against what was typed, a word at a time: words the
/// clean-up dropped are struck through in red, the words it put in their
/// place are green, and the rest reads as the transcript did. Every heard
/// word is a button: a red run can be kept as heard, and any word can be
/// given the spelling it should have had.
private struct TranscriptDiff: View {
    let heard: String
    let typed: String

    private enum Change { case same, added, removed }

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                switch run.change {
                case .same:
                    ForEach(Array(run.words.split(separator: " ").enumerated()), id: \.offset) { _, word in
                        HeardRun(words: String(word), changed: false)
                    }
                case .added:
                    ForEach(Array(run.words.split(separator: " ").enumerated()), id: \.offset) { _, word in
                        Text(word).foregroundStyle(DesignTokens.Colors.diffAdd).fontWeight(.semibold)
                    }
                case .removed:
                    HeardRun(words: run.words, changed: true)
                }
            }
        }
        .font(Square.sans(14))
        .lineSpacing(3)
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The two texts merged back into one reading order. Removals are offsets
    /// into what was heard and insertions offsets into what was typed, so the
    /// two walks advance together and every word lands once.
    private var runs: [(change: Change, words: String)] {
        let old = TranscriptDiff.words(heard)
        let new = TranscriptDiff.words(typed)
        var removed: Set<Int> = []
        var inserted: [Int: String] = [:]
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, let word, _): inserted[offset] = word
            }
        }
        var out: [(change: Change, words: String)] = []
        var o = 0, n = 0
        while o < old.count || n < new.count {
            if let word = inserted[n] { append(&out, .added, word); n += 1; continue }
            if o < old.count, removed.contains(o) { append(&out, .removed, old[o]); o += 1; continue }
            if o < old.count, n < new.count { append(&out, .same, new[n]); o += 1; n += 1; continue }
            break
        }
        return out
    }

    /// Consecutive words of the same kind are one run, so a whole phrase is
    /// struck through in one piece rather than word by word.
    private func append(_ out: inout [(change: Change, words: String)], _ change: Change, _ word: String) {
        if out.last?.change == change { out[out.count - 1].words += " " + word } else { out.append((change, word)) }
    }
}

/// A run of the transcript, and where it stands with the custom words. The
/// click opens what the dictionary's field takes: a struck-through run can be
/// kept as heard, and any run can name the spelling it should have been. A
/// run already kept, or already a spelling of a custom word, offers to be
/// forgotten instead; a struck-through one wears a check to say so. The
/// standing is read from the custom words each time, so nothing is written
/// to the history.
private struct HeardRun: View {
    let words: String
    /// Struck through by the clean-up, as opposed to left as heard.
    let changed: Bool
    @State private var store = Store.shared
    @State private var settings = Settings.shared
    @State private var open = false
    @State private var hovering = false

    private var term: String { HeardWord.term(for: words) }
    private var standing: HeardWord.Standing {
        HeardWord.standing(of: words, terms: store.terms(for: settings.customWords))
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 3) {
                Text(words)
                    .foregroundStyle(changed ? DesignTokens.Colors.diffRemove : DesignTokens.Colors.ink2)
                    .strikethrough(changed)
                if changed, standing != .unknown {
                    SquareIcon("akar-check", size: 10).foregroundStyle(DesignTokens.Colors.ink2)
                }
            }
            .padding(.horizontal, 2)
            .background(hovering || open ? DesignTokens.Colors.inkA08 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .squarePopover(isPresented: $open) {
            HeardRunMenu(term: term, standing: standing, changed: changed) { open = false }
        }
    }

    private var help: String {
        switch standing {
        case .unknown: return changed ? "keep “\(term)”, or say what it should be" : "say what it should be"
        case .kept: return "in custom words"
        case .heard(let word): return "heard as “\(term)” for \(word)"
        }
    }
}

private struct HeardRunMenu: View {
    let term: String
    let standing: HeardWord.Standing
    let changed: Bool
    let close: () -> Void
    @State private var store = Store.shared
    @State private var settings = Settings.shared
    @State private var spelling = ""
    /// Forget was clicked: the menu turns into its question.
    @State private var forgetting = false

    var body: some View {
        if forgetting {
            SquareDeleteConfirm(title: forgetTitle, confirm: "forget", cancel: { forgetting = false }) {
                forget()
                close()
            }
        } else {
            menu
        }
    }

    private var menu: some View {
        SquarePanel(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
            VStack(alignment: .leading, spacing: 8) {
                switch standing {
                case .unknown:
                    if changed {
                        Button("keep “\(term)”") {
                            settings.addCustomWord(term)
                            close()
                        }
                        .buttonStyle(SquareButtonStyle(small: true))
                    }
                    SquareField(placeholder: "should be…", text: $spelling, onSubmit: correct).frame(width: 180)
                case .kept:
                    Button("forget “\(term)”") { forgetting = true }
                        .buttonStyle(SquareButtonStyle(small: true))
                case .heard(let word):
                    Button("forget “\(term) = \(word)”") { forgetting = true }
                        .buttonStyle(SquareButtonStyle(small: true))
                }
            }
        }
    }

    private var forgetTitle: String {
        switch standing {
        case .heard(let word): "forget “\(term) = \(word)”?"
        default: "forget “\(term)”?"
        }
    }

    private func forget() {
        switch standing {
        case .kept:
            store.forgetLearned(word: term)
            settings.removeCustomWord(term)
        case .heard(let word):
            store.forgetAlias(heard: term, for: word)
        case .unknown:
            break
        }
    }

    /// The same entry as "heard = word" in the dictionary: the spelling
    /// becomes a custom word and the run a spelling the speech model produces
    /// for it.
    private func correct() {
        let w = spelling.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        settings.addCustomWord(w)
        if w.caseInsensitiveCompare(term) != .orderedSame { store.addAlias(heard: term, for: w) }
        close()
    }
}
