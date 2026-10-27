import SwiftUI

/// A settings row: the label in mono 13, a caption under it in SF and
/// anything the row adds under that (its own buttons), and its control on
/// the right. Each row is ruled above; `SquareRows` rules the last one below,
/// so rows that come and go never double a rule.
struct SquareSettingsRow<Control: View, Below: View>: View {
    let label: String
    var help: String?
    var caption: String?
    @ViewBuilder var control: Control
    @ViewBuilder var below: Below

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(label).font(Square.mono(13)).foregroundStyle(DesignTokens.Colors.ink)
                    if let help { SquareHelp(text: help) }
                }
                if let caption {
                    Text(caption)
                        .font(Square.sans(11.5))
                        .lineSpacing(2)
                        .foregroundStyle(DesignTokens.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                below.padding(.top, 6)
            }
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .frame(minHeight: 44)
        .overlay(alignment: .top) { SquareRule() }
    }
}

extension SquareSettingsRow where Below == EmptyView {
    init(label: String, help: String? = nil, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(label: label, help: help, caption: caption, control: control) { EmptyView() }
    }
}

/// Rows or groups stacked, ruled once below the last.
struct SquareRows<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .overlay(alignment: .bottom) { SquareRule() }
    }
}

/// A heading inside a group, such as "writing style", with a count or a size
/// on the right.
struct SquareSubhead: View {
    let text: String
    var trailing: String?
    var first = false
    /// What the rows under the heading are for.
    var blurb: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(text)
                Spacer()
                if let trailing { Text(trailing) }
            }
            .font(Square.mono(11))
            .foregroundStyle(DesignTokens.Colors.ink3)
            if let blurb { SquareBlurb(text: blurb) }
        }
        .padding(.top, first ? 0 : 26)
        .padding(.bottom, blurb == nil ? 8 : 14)
    }
}

/// A sentence or two saying what a group or a part of one is for.
struct SquareBlurb: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Square.sans(12.5))
            .lineSpacing(2)
            .foregroundStyle(DesignTokens.Colors.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The hairline between rows.
struct SquareRule: View {
    var color = DesignTokens.Colors.rule

    var body: some View {
        Rectangle().fill(color).frame(height: DesignTokens.hairline)
    }
}

/// A group on the one-page settings: one line with its name and what it is
/// set to, and a + that turns to − as it opens, its rows there at once under
/// the summary, after the blurb when it has one.
struct SquareGroup<Content: View>: View {
    let title: String
    let summary: String
    var blurb: String?
    @Binding var open: Bool
    @ViewBuilder var content: Content

    private static var inset: CGFloat { 4 }
    private static var titleWidth: CGFloat { 150 }
    private static var gap: CGFloat { 24 }
    /// The widest the rows run, so a control stays in reach of its label
    /// on a wide window.
    private static var rowsWidth: CGFloat { 620 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.toggle() } label: {
                HStack(spacing: SquareGroup.gap) {
                    Text(title)
                        .font(Square.mono(16))
                        .foregroundStyle(DesignTokens.Colors.ink)
                        .frame(width: SquareGroup.titleWidth, alignment: .leading)
                    Text(summary)
                        .font(Square.mono(12))
                        .foregroundStyle(DesignTokens.Colors.ink2)
                        .lineLimit(1)
                        .opacity(open ? 0 : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SquareGroupSign(open: open)
                        .padding(.trailing, 2)
                }
                .padding(.horizontal, SquareGroup.inset)
                .frame(height: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "open" : summary)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    if let blurb { SquareBlurb(text: blurb).padding(.bottom, 14) }
                    content
                }
                .frame(maxWidth: SquareGroup.rowsWidth, alignment: .leading)
                .padding(.leading, SquareGroup.inset + SquareGroup.titleWidth + SquareGroup.gap)
                .padding(.trailing, SquareGroup.inset)
                .padding(.bottom, 22)
            }
        }
        .overlay(alignment: .top) { SquareRule() }
    }
}

/// Two 12 pt bars, a + that becomes a − as the group opens.
private struct SquareGroupSign: View {
    let open: Bool

    var body: some View {
        ZStack {
            Rectangle().frame(width: 12, height: DesignTokens.hairline)
            Rectangle().frame(width: 12, height: DesignTokens.hairline)
                .rotationEffect(.degrees(open ? 180 : 90))
        }
        .frame(width: 12, height: 12)
        .foregroundStyle(DesignTokens.Colors.ink2)
    }
}

/// The columns every list by day shares: the page's margin, the select box,
/// the time, and the gaps between. Each list adds its own columns after the
/// time.
enum SquareListColumns {
    static let page: CGFloat = 20
    static let tick: CGFloat = 22
    static let time: CGFloat = 68
    static let gap: CGFloat = 16
    /// Between the select box and the row.
    static let edge: CGFloat = 4
    /// How far the columns sit inside the row's left edge.
    static let inset: CGFloat = 8
    /// Where the time column starts, from the list's edge.
    static var lead: CGFloat { tick + edge + inset }
}

/// A list's column names in ink-3 over its rows, clear of the select box,
/// `trailing` in from the row's end.
struct SquareListHead<Columns: View>: View {
    let trailing: CGFloat
    @ViewBuilder var columns: Columns

    var body: some View {
        HStack(spacing: SquareListColumns.edge) {
            Color.clear.frame(width: SquareListColumns.tick, height: 1)
            HStack(spacing: SquareListColumns.gap) { columns }
                .padding(.leading, SquareListColumns.inset)
                .padding(.trailing, trailing)
        }
        .font(Square.mono(11))
        .foregroundStyle(DesignTokens.Colors.ink3)
        .padding(.bottom, 8)
    }
}

/// A day in a list: an ink rule, the day under the time, its date beside
/// it, and how much it held, right-aligned over the last `totalWidth` of
/// the columns and `trailing` in from the row's end.
struct SquareDayHeader: View {
    let day: String
    let date: String
    let total: String
    let totalWidth: CGFloat
    let trailing: CGFloat

    var body: some View {
        HStack(spacing: SquareListColumns.edge) {
            Color.clear.frame(width: SquareListColumns.tick, height: 1)
            HStack(alignment: .firstTextBaseline, spacing: SquareListColumns.gap) {
                Text(day)
                    .font(Square.mono(12, weight: .medium))
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .frame(width: SquareListColumns.time, alignment: .leading)
                Text(date)
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(total)
                    .font(Square.mono(11))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: totalWidth, alignment: .trailing)
            }
            .padding(.leading, SquareListColumns.inset)
            .padding(.trailing, trailing)
            .padding(.top, 14)
            .padding(.bottom, 8)
        }
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.ink) }
        .padding(.top, 6)
    }
}

/// A meeting recording now, across the top of the meetings page: the slab,
/// where it is, how loud each side is, the time so far, and stop. It names no
/// one.
struct SquareLiveBand: View {
    let place: String
    let time: String
    /// 0...1, the microphone and the call; a room has no call side.
    var you: Double = 0
    var call: Double? = 0
    var stop: () -> Void = {}
    /// Transcribes what is recorded so far; nil hides the button.
    var transcribeNow: (() -> Void)?
    var transcribeBusy = false

    var body: some View {
        HStack(spacing: 16) {
            Text("recording · \(place)").font(Square.mono(12))
            Spacer()
            level("you", you)
            if let call { level("call", call) }
            Text(time).font(Square.mono(13)).monospacedDigit().frame(width: 52, alignment: .trailing)
            if let transcribeNow {
                Button("transcribe now", action: transcribeNow).buttonStyle(SquareButtonStyle()).disabled(transcribeBusy)
            }
            Button("stop", action: stop).buttonStyle(SquareButtonStyle())
        }
        .foregroundStyle(DesignTokens.Colors.onSlab)
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 46)
        .background(DesignTokens.Colors.slab)
        .environment(\.squareOnSlab, true)
    }

    private func level(_ side: String, _ value: Double) -> some View {
        HStack(spacing: 16) {
            Text(side).font(Square.mono(11)).opacity(0.7)
            SquareBar(fraction: value, width: 70, height: 4, track: DesignTokens.Colors.onSlab.opacity(0.2), fill: DesignTokens.Colors.onSlab)
        }
    }
}

/// How far along something is: a 2 pt ink line on an ink-a12 track. With
/// no width it runs as wide as it is given.
struct SquareBar: View {
    let fraction: Double
    var width: CGFloat? = 120
    var height: CGFloat = 2
    var track = DesignTokens.Colors.inkA12
    var fill = DesignTokens.Colors.ink

    var body: some View {
        if let width {
            bar(width)
        } else {
            GeometryReader { geo in bar(geo.size.width) }
                .frame(height: height)
        }
    }

    private func bar(_ width: CGFloat) -> some View {
        Rectangle()
            .fill(track)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Rectangle().fill(fill).frame(width: width * min(max(fraction, 0), 1))
            }
    }
}

/// A mono status line. Done carries a check in ink; pending is ink-2 with no icon.
struct SquareStatus: View {
    var text: String
    var done = false
    init(_ text: String, done: Bool = false) { self.text = text; self.done = done }

    var body: some View {
        HStack(spacing: 6) {
            if done {
                Image("akar-circle-check").resizable().frame(width: 13, height: 13)
            }
            Text(text).font(Square.mono(12))
        }
        .foregroundStyle(done ? DesignTokens.Colors.ink : DesignTokens.Colors.ink2)
    }
}

/// Something running with no known end: a quarter of a ring turning on an
/// ink-a20 ring, or on-slab on the slab. Still when reduce motion is on.
struct SquareSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.squareOnSlab) private var onSlab
    @State private var turned = false
    private static let turn: TimeInterval = 0.9

    var body: some View {
        let ink = onSlab ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink
        ZStack {
            Circle().stroke(onSlab ? DesignTokens.Colors.onSlab.opacity(0.2) : DesignTokens.Colors.inkA20, lineWidth: 1.5)
            Circle().trim(from: 0, to: 0.25).stroke(ink, lineWidth: 1.5)
                .rotationEffect(.degrees(turned ? 360 : 0))
        }
        .frame(width: 10, height: 10)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: SquareSpinner.turn).repeatForever(autoreverses: false)) { turned = true }
        }
    }
}

#if DEBUG
struct SquareSettingsRowSpecimen: View {
    @State private var digits = true
    @State private var mute = true
    @State private var keep = "keep everything"

    var body: some View {
        SquareSpecimen {
            SquareRows {
                SquareSettingsRow(label: "mute audio") { Toggle("", isOn: $mute) }
                SquareSettingsRow(label: "digits", help: "one → 1") { Toggle("", isOn: $digits) }
                SquareSettingsRow(label: "keep") {
                    SquareMenu(selection: $keep, options: ["keep everything", "last 500", "a month"], minWidth: 230)
                }
                SquareSettingsRow(label: "mcp", help: "assistants can list, search and read your meetings · a cloud assistant sends what it reads to its servers") {
                    Toggle("", isOn: .constant(true))
                } below: {
                    SquareLink(title: "connect an assistant") {}
                }
                SquareSettingsRow(label: "clean up", caption: "apple intelligence is off") {
                    HStack(spacing: 10) {
                        Button("system settings") {}.buttonStyle(SquareButtonStyle(small: true))
                        Toggle("", isOn: .constant(false)).disabled(true)
                    }
                }
                SquareSettingsRow(label: "folder", caption: "~/Library/Application Support/TypeMeIt/Meetings") {
                    Button("open") {}.buttonStyle(SquareButtonStyle())
                }
            }
            .frame(width: 560)
            .toggleStyle(SquareSwitchStyle())
            .labelsHidden()
        }
    }
}

struct SquareGroupSpecimen: View {
    @State private var cloudOpen = false
    @State private var keepOpen = true
    @State private var keepAudio = true

    var body: some View {
        SquareSpecimen {
            SquareRows {
                SquareGroup(title: "cloud", summary: "sky · bottom · sounds on", open: $cloudOpen) {
                    SquareRows { SquareSettingsRow(label: "sounds") { Toggle("", isOn: .constant(true)) } }
                }
                SquareGroup(title: "on this mac", summary: "keeps everything", blurb: "dictations, meetings and their audio are stored on this mac and nowhere else.", open: $keepOpen) {
                    SquareRows {
                        SquareSettingsRow(label: "keep the audio") { Toggle("", isOn: $keepAudio) }
                    }
                }
                SquareGroup(title: "clean-up", summary: "on · reads the screen · 3 of 5 styles", open: .constant(false)) { EmptyView() }
            }
            // Hung from the top at the height of both groups open, so opening
            // one moves only what is under it, as on the page.
            .frame(width: 700, height: 340, alignment: .top)
            .toggleStyle(SquareSwitchStyle())
            .labelsHidden()
        }
    }
}

struct SquareListHeadSpecimen: View {
    private static let length: CGFloat = 48

    var body: some View {
        SquareSpecimen {
            VStack(spacing: 0) {
                SquareListHead(trailing: SquareListColumns.inset) {
                    Text("time").frame(width: SquareListColumns.time, alignment: .leading)
                    Text("meeting").frame(maxWidth: .infinity, alignment: .leading)
                    Text("length").frame(width: SquareListHeadSpecimen.length, alignment: .trailing)
                }
                SquareDayHeader(day: "today", date: "thursday 24 september", total: "3 meetings · 1h 12m",
                                totalWidth: SquareListHeadSpecimen.length, trailing: SquareListColumns.inset)
                SquareDayHeader(day: "yesterday", date: "wednesday 23 september", total: "1 meeting · 11m",
                                totalWidth: SquareListHeadSpecimen.length, trailing: SquareListColumns.inset)
            }
            .frame(width: 520)
        }
    }
}

struct SquareStatusSpecimen: View {
    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "live band") {
                SquareLiveBand(place: "slack", time: "12:04", you: 0.58, call: 0.82).frame(width: 640)
            }
            SquareSpecimenLine(name: "progress") {
                Text("transcribing · 64%").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
                SquareBar(fraction: 0.64)
            }
            SquareSpecimenLine(name: "download") {
                SquareBar(fraction: 0.4, width: nil, height: 6, track: DesignTokens.Colors.inkA08).frame(width: 300)
            }
            SquareSpecimenLine(name: "done") { SquareStatus("installed", done: true) }
            SquareSpecimenLine(name: "pending") { SquareStatus("checking the model…") }
            SquareSpecimenLine(name: "running") {
                SquareSpinner()
                Text("checking the last 10 dictations").font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink)
            }
        }
    }
}

#Preview("settings row") { SquareSettingsRowSpecimen() }
#Preview("group") { SquareGroupSpecimen() }
#Preview("list head") { SquareListHeadSpecimen() }
#Preview("status") { SquareStatusSpecimen() }
#endif
