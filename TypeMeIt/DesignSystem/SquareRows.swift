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

    var body: some View {
        HStack {
            Text(text)
            Spacer()
            if let trailing { Text(trailing) }
        }
        .font(Square.mono(11))
        .foregroundStyle(DesignTokens.Colors.ink3)
        .padding(.top, first ? 0 : 26)
        .padding(.bottom, 8)
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
/// the summary.
struct SquareGroup<Content: View>: View {
    let title: String
    let summary: String
    @Binding var open: Bool
    @ViewBuilder var content: Content

    private static var inset: CGFloat { 4 }
    private static var titleWidth: CGFloat { 150 }
    private static var gap: CGFloat { 24 }

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
                content
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

/// A list row: its time on the left, what it is, and a fact on the right,
/// with a hairline above. The pointer washes it and selected it inverts to
/// the slab. With `picked`, a select box shows at its start under the
/// pointer, or always once `picking`.
struct SquareListRow: View {
    let time: String
    let title: String
    var detail: String?
    var selected = false
    var picked: Binding<Bool>?
    var picking = false
    var open: () -> Void = {}
    @Environment(\.squarePose) private var pose
    @State private var hovering = false

    var body: some View {
        let hot = pose.hot(hovering)
        HStack(spacing: 4) {
            if let picked {
                Toggle("select", isOn: picked)
                    .toggleStyle(SquareTickStyle(faint: true))
                    .labelsHidden()
                    .frame(width: 22)
                    .opacity(hot || picking || picked.wrappedValue ? 1 : 0)
            }
            Button(action: open) {
                HStack(spacing: 16) {
                    Text(time)
                        .font(Square.mono(11))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .leading)
                        .foregroundStyle(meta)
                    Text(title)
                        .font(Square.sans(13))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail {
                        Text(detail).font(Square.mono(11)).foregroundStyle(meta)
                    }
                }
                .foregroundStyle(selected ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(Rectangle().fill(selected ? DesignTokens.Colors.slab : (hot ? DesignTokens.Colors.inkA04 : .clear)))
        .overlay(alignment: .top) { SquareRule() }
        .onHover { hovering = $0 }
    }

    private var meta: Color {
        selected ? DesignTokens.Colors.onSlab.opacity(0.72) : DesignTokens.Colors.ink2
    }
}

/// The row for what records now: the slab, when it started, where, and the
/// time so far.
struct SquareLiveRow: View {
    let started: String
    let label: String
    let time: String

    var body: some View {
        HStack(spacing: 16) {
            Text(started)
                .font(Square.mono(11))
                .monospacedDigit()
                .opacity(0.72)
                .frame(width: 48, alignment: .leading)
            Text(label).font(Square.mono(12)).frame(maxWidth: .infinity, alignment: .leading)
            Text(time).font(Square.mono(12)).monospacedDigit()
        }
        .foregroundStyle(DesignTokens.Colors.onSlab)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(DesignTokens.Colors.slab)
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.onSlab.opacity(0.2)) }
    }
}

/// A day in a list: an ink rule, the day in mono 12 medium, its date, and how
/// much it held on the right.
struct SquareDayHeader: View {
    let day: String
    let date: String
    var total: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(day).font(Square.mono(12, weight: .medium)).foregroundStyle(DesignTokens.Colors.ink)
            Text(date).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3)
            Spacer()
            if let total { Text(total).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink3) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .overlay(alignment: .top) { SquareRule(color: DesignTokens.Colors.ink) }
    }
}

/// A meeting recording now, across the top of the meetings page: the slab,
/// where it is, how loud each side is, the time so far, and stop. It names no
/// one.
struct SquareLiveBand: View {
    let place: String
    let time: String
    /// 0...1, the microphone and the call.
    var you: Double = 0
    var call: Double = 0
    var stop: () -> Void = {}

    var body: some View {
        HStack(spacing: 16) {
            Text("recording · \(place)").font(Square.mono(12))
            Spacer()
            level("you", you)
            level("call", call)
            Text(time).font(Square.mono(13)).monospacedDigit().frame(width: 52, alignment: .trailing)
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

/// How far along something is: a 2 pt ink line on an ink-a12 track.
struct SquareBar: View {
    let fraction: Double
    var width: CGFloat = 120
    var height: CGFloat = 2
    var track = DesignTokens.Colors.inkA12
    var fill = DesignTokens.Colors.ink

    var body: some View {
        Rectangle()
            .fill(track)
            .frame(width: width, height: height)
            .overlay(alignment: .leading) {
                Rectangle().fill(fill).frame(width: width * min(max(fraction, 0), 1))
            }
    }
}

/// Something running with no known end: a quarter of a ring turning on an
/// ink-a20 ring. Still when reduce motion is on.
struct SquareSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turned = false
    private static let turn: TimeInterval = 0.9

    var body: some View {
        ZStack {
            Circle().stroke(DesignTokens.Colors.inkA20, lineWidth: 1.5)
            Circle().trim(from: 0, to: 0.25).stroke(DesignTokens.Colors.ink, lineWidth: 1.5)
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
    @State private var space = true
    @State private var keep = "keep everything"

    var body: some View {
        SquareSpecimen {
            SquareRows {
                SquareSettingsRow(label: "space after typing") { Toggle("", isOn: $space) }
                SquareSettingsRow(label: "digits", help: "one → 1") { Toggle("", isOn: $digits) }
                SquareSettingsRow(label: "keep") {
                    SquareMenu(selection: $keep, options: ["keep everything", "the last 500", "a month"], minWidth: 230)
                }
                SquareSettingsRow(label: "mcp", caption: "lets assistants, including cloud ones, read your meetings") {
                    Toggle("", isOn: .constant(true))
                } below: {
                    SquareLink(title: "connect an assistant") {}
                }
                SquareSettingsRow(label: "clean up", caption: "apple intelligence is off - turn it on in system settings to clean up and learn from corrections") {
                    HStack(spacing: 10) {
                        Button("system settings") {}.buttonStyle(SquareButtonStyle(small: true))
                        Toggle("", isOn: .constant(false)).disabled(true)
                    }
                }
                SquareSettingsRow(label: "meetings folder", caption: "~/Library/Application Support/TypeMeIt/Meetings") {
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
    @State private var typingOpen = true
    @State private var space = true
    @State private var copy = false

    var body: some View {
        SquareSpecimen {
            SquareRows {
                SquareGroup(title: "cloud", summary: "sky · bottom · sounds on", open: $cloudOpen) {
                    SquareRows { SquareSettingsRow(label: "sounds") { Toggle("", isOn: .constant(true)) } }
                }
                SquareGroup(title: "typing", summary: "space after · no key after", open: $typingOpen) {
                    SquareRows {
                        SquareSettingsRow(label: "space after typing") { Toggle("", isOn: $space) }
                        SquareSettingsRow(label: "offer to copy when no text box is focused") { Toggle("", isOn: $copy) }
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

struct SquareListRowSpecimen: View {
    @State private var picked = false

    var body: some View {
        SquareSpecimen {
            VStack(spacing: 0) {
                SquareDayHeader(day: "today", date: "24 september", total: "3 meetings · 1h 12m")
                SquareListRow(time: "10:21", title: "pricing page review", detail: "11m")
                SquareListRow(time: "10:21", title: "pricing page review", detail: "11m").environment(\.squarePose, .hover)
                SquareListRow(time: "10:21", title: "pricing page review", detail: "11m", selected: true)
                SquareLiveRow(started: "10:48", label: "recording · slack huddle", time: "12:04")
                SquareListRow(time: "09:02", title: "select box, under the pointer", detail: "4m", picked: $picked)
                    .environment(\.squarePose, .hover)
                SquareListRow(time: "08:47", title: "select box, picked", detail: "2m", picked: .constant(true), picking: true)
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
            SquareSpecimenLine(name: "running") {
                SquareSpinner()
                Text("checking the last 10 dictations").font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink)
            }
        }
    }
}

#Preview("settings row") { SquareSettingsRowSpecimen() }
#Preview("group") { SquareGroupSpecimen() }
#Preview("list row") { SquareListRowSpecimen() }
#Preview("status") { SquareStatusSpecimen() }
#endif
