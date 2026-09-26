import SwiftUI

/// A removable chip: the label in mono on an ink-a08 wash, a cross at its end.
struct SquareChip: View {
    let text: String
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(text).centredLetters(text)
            if let remove {
                SquareCross(help: "remove \(text)", action: remove, rest: DesignTokens.Colors.ink2)
            }
        }
        .font(Square.mono(Square.controlSize))
        .foregroundStyle(DesignTokens.Colors.ink)
        .padding(.leading, 8)
        .padding(.trailing, remove == nil ? 8 : 4)
        .frame(height: 22)
        .background(DesignTokens.Colors.inkA08)
    }
}

/// A dictionary word: a sparkle first when it was learned from a correction
/// rather than typed in, the word, what else it has been heard as in ink-3,
/// and a cross that forgets it.
struct SquareWordChip: View {
    let word: String
    var heardAs: [String] = []
    /// What the correction changed, for the sparkle's tooltip.
    var learnedFrom: String?
    var forget: (() -> Void)?
    @State private var forgetting = false

    var body: some View {
        HStack(spacing: 6) {
            if let learnedFrom {
                SquareIcon("akar-sparkles", size: 11)
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .help("learned from a correction: heard “\(learnedFrom)”")
            }
            Text(word).centredLetters(word)
            if !heardAs.isEmpty {
                let heard = heardAs.joined(separator: ", ")
                Text(heard)
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .centredLetters(heard, size: 11)
                    .help("heard as \(heard)")
            }
            if forget != nil {
                SquareCross(help: "forget \(word)", action: { forgetting.toggle() }, rest: DesignTokens.Colors.ink3)
            }
        }
        .font(Square.mono(Square.controlSize))
        .foregroundStyle(DesignTokens.Colors.ink)
        .padding(.leading, 9)
        .padding(.trailing, forget == nil ? 9 : 4)
        .frame(height: 26)
        .background(DesignTokens.Colors.inkA08)
        .squareConfirmDelete(isPresented: $forgetting, title: "forget “\(word)”?",
                             detail: heardAs.isEmpty ? SquareDeleteConfirm.gone(1) : "it and \(counted(heardAs.count, "spelling")) can't be recovered.",
                             confirm: "forget") { forget?() }
    }
}

/// A short fact about a row, in mono 11 on an ink-a08 wash.
struct SquareTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Square.mono(11))
            .foregroundStyle(DesignTokens.Colors.ink2)
            .centredLetters(text, size: 11)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(DesignTokens.Colors.inkA08)
    }
}

/// Something that went wrong with a row, said in full ink with nothing
/// behind it, so the button that fixes it is the only thing that looks
/// pressable.
struct SquareFailure: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Square.mono(11))
            .foregroundStyle(DesignTokens.Colors.ink)
    }
}

/// The cross at the end of a chip: 8 pt, in its own small target, going to
/// ink under the pointer.
private struct SquareCross: View {
    let help: String
    let action: () -> Void
    let rest: Color
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SquareIcon("akar-cross", size: 8)
                .foregroundStyle(pose.hot(hovering) ? DesignTokens.Colors.ink : rest)
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A square field: the control rule round an SF 13 line, with an icon in
/// front when it searches. Focus takes the edge to ink.
struct SquareField: View {
    let placeholder: String
    @Binding var text: String
    var icon: String?
    var onSubmit: () -> Void = {}
    @State private var focused = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon { SquareIcon(icon, size: 13).foregroundStyle(DesignTokens.Colors.ink3) }
            SquareTextInput(placeholder: placeholder, text: $text, font: Square.appKitSans(13), focused: $focused, onSubmit: onSubmit)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .overlay(Rectangle().strokeBorder(focused ? DesignTokens.Colors.ink : DesignTokens.Colors.ruleControl, lineWidth: DesignTokens.hairline))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }
}

#if DEBUG
struct SquareChipSpecimen: View {
    @State private var words = ["typeme.it", "priya", "parakeet"]

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "chip") {
                SquareChip(text: "zoom") {}
                SquareChip(text: "slack")
            }
            SquareSpecimenLine(name: "chip hover", pose: .hover) { SquareChip(text: "zoom") {} }
            SquareSpecimenLine(name: "word") {
                SquareWordChip(word: "typeme.it", heardAs: ["titemere", "type me it"]) {}
                SquareWordChip(word: "priya", heardAs: ["pria"], learnedFrom: "pria") {}
                SquareWordChip(word: "parakeet") {}
            }
            SquareSpecimenLine(name: "try it") {
                ForEach(words, id: \.self) { w in
                    SquareWordChip(word: w) { words.removeAll { $0 == w } }
                }
            }
            SquareSpecimenLine(name: "tag") {
                SquareTag(text: "only your side")
                SquareTag(text: "waiting for the speech model")
            }
            SquareSpecimenLine(name: "failure") {
                SquareFailure(text: "transcription failed")
                Button("retry") {}.buttonStyle(SquareButtonStyle(small: true))
            }
        }
    }
}

struct SquareFieldSpecimen: View {
    @State private var search = ""
    @State private var word = "pyannote"

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "search") { SquareField(placeholder: "search", text: $search, icon: "akar-search").frame(width: 220) }
            SquareSpecimenLine(name: "filled") { SquareField(placeholder: "add a word, or heard = word", text: $word).frame(width: 360) }
        }
    }
}

#Preview("chip") { SquareChipSpecimen() }
#Preview("field") { SquareFieldSpecimen() }
#endif
