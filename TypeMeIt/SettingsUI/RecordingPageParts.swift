import SwiftUI

// The parts a dictation's page and a meeting's page share.

/// Across the top of the page: back to the list on the left, the page's
/// actions on the right, ruled below.
struct PageTopBar<Actions: View>: View {
    /// The list the back button returns to.
    let list: String
    /// Esc goes back unless a field on the page has it.
    var backShortcut: KeyboardShortcut? = .cancelAction
    let back: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 6) {
            Button(action: back) {
                Label {
                    Text(list)
                } icon: {
                    SquareIcon("akar-chevron-down", size: 10).rotationEffect(.degrees(90))
                }
            }
            .buttonStyle(SquareButtonStyle(kind: .quiet))
            .keyboardShortcut(backShortcut)
            Spacer(minLength: 0)
            actions
        }
        .padding(.top, 12)
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .padding(.bottom, 12)
        .overlay(alignment: .bottom) { SquareRule() }
    }
}

/// The copy icon, which turns to a check once it has copied.
struct PageCopyButton: View {
    /// What the button does, for its tooltip and for VoiceOver.
    let help: String
    let copy: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            copy()
            copied = true
        } label: {
            SquareIcon(copied ? "akar-check" : "akar-copy", size: copied ? 12 : 14)
        }
        .buttonStyle(SquareIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The page's foot: the player while the audio is kept, or a line saying
/// none was. Playback belongs to the page: leaving it stops it.
struct PageAudioFoot: View {
    let id: UUID
    /// The audio's tracks, played together; nil when none was kept.
    let urls: [URL]?
    let durationMs: Int
    @State private var player = RecordingPlayer.shared

    var body: some View {
        VStack(spacing: 0) {
            if let urls {
                RecordingPlayerBar(id: id, urls: urls, durationMs: durationMs)
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
        .onDisappear { if player.playing == id { player.stop() } }
    }
}

/// Play or pause on the slab, where it is along a bar to click or drag, and
/// the time over the length.
private struct RecordingPlayerBar: View {
    let id: UUID
    let urls: [URL]
    let durationMs: Int
    @State private var player = RecordingPlayer.shared

    var body: some View {
        let loaded = player.playing == id
        let running = loaded && !player.paused
        let total = loaded ? player.duration : Double(durationMs) / 1000
        // Ticks only while playing: each tick lays the bar out again.
        TimelineView(.animation(minimumInterval: 0.1, paused: !running)) { _ in
            let at = loaded ? player.currentTime : 0
            HStack(spacing: 18) {
                Button {
                    if running { player.pause() } else { player.play(id: id, urls: urls) }
                } label: {
                    SquareIcon(running ? "akar-pause" : "akar-play", size: 14)
                }
                .buttonStyle(SquarePlayButtonStyle())
                .help(running ? "pause" : "play")
                .accessibilityLabel(running ? "pause" : "play")
                SquareScrubber(fraction: total > 0 ? at / total : 0) { fraction in
                    if loaded { player.seek(to: fraction * total) } else { player.play(id: id, urls: urls, from: fraction * total) }
                }
                HStack(spacing: 0) {
                    Text(TranscriptRender.timestamp(ms: Int(at * 1000)))
                    Text(" / \(TranscriptRender.timestamp(ms: Int(total * 1000)))").foregroundStyle(DesignTokens.Colors.ink3)
                }
                .font(Square.mono(12))
                .monospacedDigit()
            }
        }
        // As tall as the sidebar's foot beside it, which pads a 34 pt row the same way.
        .padding(.vertical, SquareSidebarLayout.footDrop)
        .padding(.leading, 20)
        .padding(.trailing, 24)
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.ink) }
    }
}

/// A fact in the page's rail, such as how long a step took. One still to
/// come is in ink-3.
struct RailFact {
    let key: String
    let value: String
    var waiting = false
}

/// Facts in the page's rail: the key on the left, its value on the right,
/// each between hairlines.
struct RailFacts: View {
    let facts: [RailFact]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(facts, id: \.key) { fact in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(fact.key).foregroundStyle(DesignTokens.Colors.ink3)
                    Spacer(minLength: 0)
                    Text(fact.value)
                        .foregroundStyle(fact.waiting ? DesignTokens.Colors.ink3 : DesignTokens.Colors.ink)
                        .multilineTextAlignment(.trailing)
                }
                .font(Square.mono(11))
                .monospacedDigit()
                .padding(.vertical, 6)
                .overlay(alignment: .top) { SquareRule() }
            }
        }
        .overlay(alignment: .bottom) { SquareRule() }
    }
}
