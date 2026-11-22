import AppKit
import SwiftUI

/// The strip's coordinate space, where the slab and the tabs' frames are measured.
private let squareTabsStrip = "square-tabs"

/// One tab in a `SquareTabs` strip.
struct SquareTab: Hashable {
    enum State { case idle, running, failed }
    let name: String
    var state: State = .idle
}

/// Tabs over a framed panel: the picked tab is a slab joined to the panel's
/// ink frame, the rest are ink3 labels. A running tab shows a spinner, a
/// failed one says so after its name. The content brings its own padding, so
/// a scroll inside the panel runs to the frame.
///
/// Picking another tab moves the slab there in four hard steps, and the tab
/// it left keeps a dithered ghost of it that thins out over a few frames.
/// Under Reduce Motion the slab just moves.
struct SquareTabs<Trailing: View, Content: View>: View {
    let tabs: [SquareTab]
    @Binding var picked: Int
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: (Int) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                SquareTabStrip(tabs: tabs, picked: $picked)
                Spacer(minLength: 12)
                trailing()
            }
            content(picked)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().stroke(DesignTokens.Colors.ink, lineWidth: 1))
        }
    }
}

/// The tab names and the slab under the picked one. Its own view, so each
/// frame of the slab's jump redraws the strip and not the panel under it.
struct SquareTabStrip: View {
    let tabs: [SquareTab]
    @Binding var picked: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Each tab's frame in the strip.
    @State private var frames: [Int: CGRect] = [:]
    @State private var motion = SquareSlabMotion()
    @State private var jump: Task<Void, Never>?

    var body: some View {
        // Tabs past the panel's width scroll sideways, the picked one kept in view.
        ScrollViewReader { reader in
            ScrollView(.horizontal) {
                strip
            }
            .scrollIndicators(.never)
            .onAppear { reader.scrollTo(picked) }
            .onChange(of: picked) { _, now in
                withAnimation(.easeOut(duration: 0.2)) { reader.scrollTo(now) }
                jumpSlab(to: now)
            }
        }
    }

    /// The tabs over the slab and the ghost it leaves, measured in their own space.
    private var strip: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                let onSlab = isUnderSlab(index)
                Button { picked = index } label: {
                    HStack(spacing: 6) {
                        if tab.state == .running {
                            SquareSpinner().frame(width: 9, height: 9).environment(\.squareOnSlab, onSlab)
                        }
                        Text(tab.name)
                        if tab.state == .failed {
                            Text("· failed").foregroundStyle(onSlab ? DesignTokens.Colors.onSlab : DesignTokens.Colors.diffRemove)
                        }
                    }
                    .font(Square.mono(12))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(onSlab ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink3)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .contentShape(Rectangle())
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(squareTabsStrip)) } action: { frame in
                        frames[index] = frame
                        if index == picked && jump == nil { motion.slab = frame }
                    }
                }
                .buttonStyle(.plain)
                .id(index)
            }
        }
        .background(alignment: .topLeading) { SquareSlabLayer(motion: motion) }
        .coordinateSpace(.named(squareTabsStrip))
    }

    /// The slab covers the middle of this tab, so its label is drawn on the
    /// slab. Before layout, that is the picked tab.
    private func isUnderSlab(_ index: Int) -> Bool {
        motion.covers(frames[index]) ?? (index == picked)
    }

    private func jumpSlab(to index: Int) {
        jump?.cancel()
        jump = nil
        guard let target = frames[index], motion.start(to: target, reduceMotion: reduceMotion) else { return }
        jump = Task {
            guard await SquarePixel.run({ motion.advance() }) else { return }
            motion.settle(at: frames[index])
            jump = nil
        }
    }
}

/// One line of a Claude Code run as its terminal prints it.
enum SquareClaudeLine: Hashable {
    case prompt(String)
    case meta(String)
    case call(String, result: String?)
    case text(String)
    case error(String)
}

/// A Claude Code run: what went in, the prompt and each tool call with what
/// came back, shaded together; Claude's words under it on the page; and how
/// it ended. Read only.
struct SquareClaudeThread: View {
    enum Status { case running, done, failed }
    let lines: [SquareClaudeLine]
    let status: Status
    /// "12 s", "4 s · claude-sonnet-5", "failed"; empty for none.
    let footer: String
    /// While running, the footer leads with the seconds since then, counted
    /// in the footer alone so the rest of the thread is not redrawn each second.
    var runningSince: Date?
    /// Claude's words first, the prompt folded away with the tool calls under them.
    var foldsPrompt = false
    /// Claude Code's session, which a click copies as a resume command.
    var sessionID: String?
    /// Opens the run in the Claude desktop app; nil offers nothing.
    var openInClaude: (() -> Void)?
    var stop: () -> Void = {}
    /// Offered on a failed run; nil offers nothing.
    var runAgain: (() -> Void)?

    /// Steps start open; the chevron folds them.
    @State private var stepsOpen = true
    /// With `foldsPrompt`, the prompt and steps start folded.
    @State private var promptOpen = false

    private var steps: [SquareClaudeLine] {
        lines.filter { if case .call = $0 { true } else { false } }
    }

    private var said: [SquareClaudeLine] {
        lines.filter { if case .text = $0 { true } else if case .error = $0 { true } else { false } }
    }

    private var callCount: Int {
        lines.filter { if case .call = $0 { true } else { false } }.count
    }

    private var counting: Date? { status == .running ? runningSince : nil }

    private var hasFooter: Bool {
        !footer.isEmpty || sessionID != nil || openInClaude != nil || status == .running || status == .failed && runAgain != nil
    }

    /// Running with nothing back yet: the prompt's mark spins, as the pill's does.
    private var waiting: Bool {
        status == .running && lines.allSatisfy { if case .prompt = $0 { true } else { false } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if foldsPrompt { answer }
            workings
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DesignTokens.Colors.inkA04)
            if !foldsPrompt { answer }
            if hasFooter { footerRow }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// The prompt and each tool call, shaded together.
    @ViewBuilder private var workings: some View {
        if foldsPrompt {
            let open = promptOpen
            VStack(alignment: .leading, spacing: 12) {
                fold(open: open, label: callCount > 0 ? "prompt · \(counted(callCount, "tool call"))" : "prompt") { promptOpen = !open }
                if open {
                    VStack(alignment: .leading, spacing: 12) {
                        prompts
                        if !steps.isEmpty { stepRows }
                    }
                    .padding(.leading, 15)
                }
            }
        } else {
            let open = stepsOpen
            VStack(alignment: .leading, spacing: 12) {
                prompts
                if callCount > 0 || status == .running && !waiting {
                    VStack(alignment: .leading, spacing: 8) {
                        fold(open: open, label: counted(callCount, "tool call")) { stepsOpen = !open }
                        if open { stepRows.padding(.leading, 15) }
                    }
                }
            }
        }
    }

    private var prompts: some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            if case .prompt = line { row(line) }
        }
    }

    private var stepRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, line in row(line) }
        }
    }

    /// A chevron and `label`, spinning while the run goes on; a click folds or opens.
    private func fold(open: Bool, label: String, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                SquareIcon("akar-chevron-down", size: 9).rotationEffect(.degrees(open ? 0 : -90))
                Text(label).font(Square.mono(12))
                if status == .running { SquareClaudeSpinner() }
            }
            .foregroundStyle(DesignTokens.Colors.ink3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var answer: some View {
        if !said.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(said.enumerated()), id: \.offset) { _, line in row(line) }
            }
        }
    }

    private var footerRow: some View {
        HStack(spacing: 8) {
            if let counting {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    mono(["\(Int(context.date.timeIntervalSince(counting))) s", footer].filter { !$0.isEmpty }.joined(separator: " · "), DesignTokens.Colors.ink3)
                }
            } else if !footer.isEmpty {
                mono(footer, DesignTokens.Colors.ink3)
            }
            if let sessionID {
                // Reads as the rest of the footer; a click copies the resume command.
                mono(footer.isEmpty && counting == nil ? sessionID : "· \(sessionID)", DesignTokens.Colors.ink3)
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("claude --resume \(sessionID)", forType: .string)
                    }
                    .help("click to copy claude --resume")
                    .onHover { inside in
                        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                    }
            }
            Spacer()
            if status != .running, let openInClaude {
                SquareClaudeButton(title: "continue in claude", action: openInClaude)
            }
            if status == .running {
                Button("stop", action: stop).buttonStyle(SquareButtonStyle(kind: .quiet))
            }
            if status == .failed, let runAgain {
                Button("run again", action: runAgain).buttonStyle(SquareButtonStyle(kind: .quiet))
            }
        }
    }

    @ViewBuilder private func row(_ line: SquareClaudeLine) -> some View {
        switch line {
        case .prompt(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // One width for both marks, so the prompt stays put when the spinner stops.
                Group {
                    if waiting {
                        SquareClaudeSpinner().foregroundStyle(DesignTokens.Colors.ink3)
                    } else {
                        mono(">", DesignTokens.Colors.ink3)
                    }
                }
                .frame(width: SquareClaudeSpinner().width, alignment: .leading)
                mono(text, DesignTokens.Colors.ink).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .meta(let text):
            mono(text, DesignTokens.Colors.ink3)
        case .call(let name, let result):
            VStack(alignment: .leading, spacing: 2) {
                mono("⏺ \(name)", DesignTokens.Colors.ink2).lineLimit(1)
                if let result { mono("  ⎿ \(result)", DesignTokens.Colors.ink3).lineLimit(1) }
            }
            // One line each, cut at the panel's edge even while selected.
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        case .text(let reply):
            ClaudeMarkdown(reply: reply, font: Square.sans(14), colour: DesignTokens.Colors.ink)
        case .error(let text):
            mono("✗ \(text)", DesignTokens.Colors.diffRemove)
        }
    }

    private func mono(_ text: String, _ colour: Color) -> some View {
        Text(text).font(Square.mono(12)).foregroundStyle(colour)
    }
}

#if DEBUG
/// The meeting page's top: summary and each hook's latest result as tabs,
/// the transcript underneath.
struct SquareTabsSpecimen: View {
    @State private var picked = 1
    private let tabs = [
        SquareTab(name: "summary"),
        SquareTab(name: "who decided what"),
        SquareTab(name: "linear follow-ups", state: .running),
        SquareTab(name: "email recap", state: .failed),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("call tracking sync").font(Square.mono(30)).foregroundStyle(DesignTokens.Colors.ink)
                Text("monday 19 october · 20:02–20:31").font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink2)
            }
            SquareTabs(tabs: tabs, picked: $picked) {
                Button("run hooks") {}.buttonStyle(SquareButtonStyle(kind: .quiet))
            } content: { index in
                panel(tabs[index], isSummary: index == 0)
            }
            VStack(alignment: .leading, spacing: 12) {
                SquareSubhead(text: "transcript")
                Text(.init("**alex** 00:12  So the main thing today is the three call-tracking surfaces…\n\n**sam** 00:31  Right, and I think the inquiry feed should link out rather than merge."))
                    .font(.system(size: 14)).foregroundStyle(DesignTokens.Colors.ink2).lineSpacing(5)
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder private func panel(_ tab: SquareTab, isSummary: Bool) -> some View {
        let body = Font.system(size: 14)
        if isSummary {
            Text("The team agreed to merge the call log, inquiry feed and reporting into one view, starting this week. Sam owns scope.")
                .font(body).foregroundStyle(DesignTokens.Colors.ink2).lineSpacing(5)
        } else {
            SquareClaudeThread(lines: [.prompt("list each decision and who made it"), .meta("sonnet 5")], status: tab.state == .running ? .running : tab.state == .failed ? .failed : .done, footer: "4 s", foldsPrompt: true)
        }
    }
}

/// Claude's output in each state, on its own.
struct SquareClaudeThreadSpecimen: View {
    private let start: [SquareClaudeLine] = [
        .prompt("list each decision and who made it"),
                .call("typemeit get_meeting", result: "call tracking sync · 29 min"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 40) {
            SquareClaudeThread(lines: start + [.call("linear save_issue \"Unify call log\"", result: nil)], status: .running, footer: "12 s")
            SquareClaudeThread(lines: start + [.text("Decisions made:\n\n1. **Unify call tracking this week**, decided by Alex.\n2. **Link out from the inquiry feed**, decided by Sam.")], status: .done, footer: "done · 4 s · 20:34")
            SquareClaudeThread(lines: start + [.text("Calls by surface:\n\n```\n+--------------+-------+\n| surface      | calls |\n+--------------+-------+\n| call log     |    41 |\n| inquiry feed |    17 |\n+--------------+-------+\n```\n\nThe call log takes most of them.")], status: .done, footer: "done · 6 s · 20:34")
            SquareClaudeThread(lines: start + [.error("claude code timed out after 120 s")], status: .failed, footer: "failed · 120 s · 20:34")
            // A hook's tab on the meeting page: the answer first, the prompt folded.
            SquareClaudeThread(lines: start + [.text("Decisions made:\n\n1. **Unify call tracking this week**, decided by Alex.\n2. **Link out from the inquiry feed**, decided by Sam.")], status: .done, footer: "4 s · 20:34", foldsPrompt: true)
        }
    }
}

#Preview("tabs") { SquareTabsSpecimen().padding(24) }
#endif
