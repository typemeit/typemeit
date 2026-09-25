import FoundationModels
import SwiftUI

/// The custom words: learning from corrections, each word with what else it
/// has been heard as, the field that adds one, and what a new word would have
/// changed in the last dictations.
struct DictionaryTab: View {
    @State private var settings = Settings.shared
    @State private var store = Store.shared
    @State private var verifier = VerifyCustomWord.shared
    @State private var player = RecordingPlayer.shared
    @State private var newWord = ""
    @State private var availability = PostProcessor.availability
    /// Apple Intelligence is switched in System Settings, not in the app, so
    /// it is re-read while the window is up.
    private let poll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var modelAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if Sandbox.readsOtherApps {
                    SquareRows {
                        SquareSettingsRow(label: "learn from corrections", caption: modelAvailable ? nil : "needs apple intelligence") {
                            Toggle("learn from corrections", isOn: $settings.learnFromCorrections)
                                .toggleStyle(SquareSwitchStyle())
                                .labelsHidden()
                                .disabled(!modelAvailable)
                        }
                    }
                }
                if !settings.customWords.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(settings.customWords, id: \.self) { word in
                            SquareWordChip(word: word, heardAs: store.aliases(for: word), learnedFrom: store.learnedRecord(for: word)?.heard) {
                                store.forgetLearned(word: word)
                                settings.removeCustomWord(word)
                            }
                        }
                    }
                    .padding(.vertical, 18)
                }
                SquareField(placeholder: "add a word, or heard = word", text: $newWord, onSubmit: addWordAndVerify)
                    .frame(width: 360)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { SquareRule() }
                verifyPanel
            }
            .frame(maxWidth: 780, alignment: .leading)
            .padding(.top, 26)
            .padding(.horizontal, 40)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { availability = PostProcessor.availability }
        .onReceive(poll) { _ in availability = PostProcessor.availability }
    }

    /// "Titemere = typeme.it" adds Titemere as a spelling the speech model
    /// produces for typeme.it; a bare word is added on its own.
    private func addWordAndVerify() {
        let entry = newWord.trimmingCharacters(in: .whitespaces)
        guard !entry.isEmpty else { newWord = ""; return }
        var heard: String?
        var w = entry
        if let eq = entry.firstIndex(of: "=") {
            heard = String(entry[..<eq]).trimmingCharacters(in: .whitespaces)
            w = String(entry[entry.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !w.isEmpty, heard?.isEmpty == false else { return }
        }
        let existing = store.terms(for: settings.customWords.filter { $0.caseInsensitiveCompare(w) != .orderedSame })
        settings.addCustomWord(w)
        if let heard { store.addAlias(heard: heard, for: w) }
        newWord = ""
        verifier.run(for: w, existing: existing, aliases: store.aliases(for: w), history: store.history)
    }

    @ViewBuilder private var verifyPanel: some View {
        switch verifier.state {
        case .idle:
            EmptyView()
        case .checking(let word, let scanned, let total):
            HStack(spacing: 10) {
                SquareSpinner()
                Text("checking recent dictations for '\(word)' · \(scanned)/\(total)")
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("stop") { verifier.clear() }.buttonStyle(SquareButtonStyle(kind: .quiet))
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { SquareRule() }
            .padding(.top, 16)
        case .done(let word, let matches, let scanned):
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    SquareIcon("akar-sparkles", size: 12).foregroundStyle(DesignTokens.Colors.ink2)
                    Text(headline(for: word, matches: matches, scanned: scanned))
                        .font(Square.mono(12))
                        .foregroundStyle(DesignTokens.Colors.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("dismiss") { verifier.clear() }.buttonStyle(SquareButtonStyle(kind: .quiet))
                }
                ForEach(matches) { match in verifyRow(match) }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) { SquareRule() }
            .padding(.top, 16)
        }
    }

    private func headline(for word: String, matches: [VerifyCustomWord.Match], scanned: Int) -> String {
        if matches.isEmpty { return "'\(word)' would not have changed the last \(counted(scanned, "dictation"))" }
        return "'\(word)' would have caught \(matches.count) of the last \(counted(scanned, "dictation"))"
    }

    /// A dictation the word would have changed: when, its audio, and the
    /// words before and after.
    private func verifyRow(_ match: VerifyCustomWord.Match) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(match.timestamp.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))
                .font(Square.mono(11))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.Colors.ink3)
                .frame(width: 40, alignment: .leading)
                .padding(.top, 6)
            ZStack { playButton(match) }.frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(match.before).foregroundStyle(DesignTokens.Colors.diffRemove).strikethrough()
                Text(match.after).foregroundStyle(DesignTokens.Colors.diffAdd)
            }
            .font(Square.sans(13))
            .lineSpacing(2)
            .textSelection(.enabled)
            .padding(.top, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .top) { SquareRule() }
        .padding(.top, 8)
    }

    @ViewBuilder private func playButton(_ match: VerifyCustomWord.Match) -> some View {
        if match.recordingFile != nil, let entry = store.history.first(where: { $0.id == match.id }) {
            let on = player.playing == match.id
            Button { player.toggle(entry) } label: { SquareIcon(on ? "akar-stop" : "akar-play", size: 12) }
                .buttonStyle(SquareIconButtonStyle())
                .help(on ? "stop" : "play the audio")
                .accessibilityLabel(on ? "stop" : "play the audio")
        }
    }
}
