import SwiftUI

/// What opens under a speaker's name field on the meeting page: the clip
/// playing, its words inking in as they are said, then the names to give
/// it. The call's names carry the number key that picks them.
struct SpeakerNames: View {
    let meetingID: UUID
    let clips: [SpeakerAssign.Clip]
    let clip: Int
    let options: [SpeakerAssign.Option]
    let pick: Int
    /// Plays the clip at an index.
    let play: (Int) -> Void
    let choose: (SpeakerAssign.Option) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if clips.indices.contains(clip) {
                let current = clips[clip]
                HStack(spacing: 8) {
                    Text(TranscriptRender.timestamp(ms: current.startMs))
                        .monospacedDigit()
                    if clips.count > 1 {
                        Button("\(clip + 1)/\(clips.count) ›") { play((clip + 1) % clips.count) }
                            .buttonStyle(.plain)
                            .help("another clip")
                    }
                }
                .font(Square.mono(11))
                .foregroundStyle(DesignTokens.Colors.ink3)
                .padding(.horizontal, 6)
                .padding(.top, 6)
                Button { play(clip) } label: { SpeakerQuote(clip: current, meetingID: meetingID) }
                    .buttonStyle(.plain)
                    .help("play again")
                    .padding(.horizontal, 6)
                    .padding(.top, 3)
                    .padding(.bottom, 4)
            }
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                if i == 0 || options[i - 1].group != option.group { head(option.group, first: i == 0) }
                SpeakerNameRow(option: option, picked: i == pick) { choose(option) }
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
    }

    @ViewBuilder private func head(_ group: SpeakerAssign.Option.Group, first: Bool) -> some View {
        switch group {
        case .voice: groupTitle("by voice")
        case .call: groupTitle("on this call")
        case .past: groupTitle("past calls")
        case .same: groupTitle("same person as")
        case .merged: groupTitle("merged in")
        case .other: if !first { SquareRule().padding(.vertical, 5).padding(.horizontal, 2) }
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(Square.mono(11))
            .foregroundStyle(DesignTokens.Colors.ink3)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// One name in the list: its key, the name, and what picking it does.
private struct SpeakerNameRow: View {
    let option: SpeakerAssign.Option
    let picked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if let key = option.key {
                    Text("\(key)")
                        .foregroundStyle(picked ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink3)
                        .frame(width: 16, alignment: .leading)
                }
                Text(option.label).lineLimit(1)
                Spacer(minLength: 10)
                Text(option.detail).foregroundStyle(picked ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink3)
            }
            .font(Square.mono(12))
            .foregroundStyle(picked ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(picked ? DesignTokens.Colors.slab : hovering ? DesignTokens.Colors.inkA08 : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A clip's words in quotes. While it plays they ink in at the pace of the
/// clip, so the reader sees where in the line the voice is.
private struct SpeakerQuote: View {
    let clip: SpeakerAssign.Clip
    let meetingID: UUID
    @State private var player = RecordingPlayer.shared

    var body: some View {
        let live = player.playing == meetingID && !player.paused
        // Ticks only while playing.
        TimelineView(.animation(minimumInterval: 0.05, paused: !live)) { _ in
            Text(inked(live: live))
                .font(Square.sans(12.5))
                .lineSpacing(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func inked(live: Bool) -> AttributedString {
        let words = clip.text.split(separator: " ")
        let at = player.currentTime * 1000
        let inClip = live && at >= Double(clip.startMs) && at <= Double(clip.endMs)
        let said = inClip ? Int(((at - Double(clip.startMs)) / Double(max(1, clip.endMs - clip.startMs)) * Double(words.count)).rounded(.up)) : 0
        var out = AttributedString("“")
        for (i, word) in words.enumerated() {
            var piece = AttributedString(i == 0 ? String(word) : " " + word)
            piece.foregroundColor = inClip ? (i < said ? DesignTokens.Colors.ink : DesignTokens.Colors.ink3) : DesignTokens.Colors.ink2
            out += piece
        }
        out += AttributedString("”")
        return out
    }
}
