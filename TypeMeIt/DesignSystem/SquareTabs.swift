import AppKit
import SwiftUI

/// One tab in a `SquareTabs` strip.
struct SquareTab: Hashable {
    enum State { case idle, running, failed }
    let name: String
    var state: State = .idle
}

/// Tabs over a framed panel: the picked tab is a slab joined to the panel's
/// ink frame, the rest are ink3 labels. A running tab shows a spinner, a
/// failed one says so after its name.
struct SquareTabs<Trailing: View, Content: View>: View {
    let tabs: [SquareTab]
    @Binding var picked: Int
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: (Int) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                    let isPicked = picked == index
                    Button { picked = index } label: {
                        HStack(spacing: 6) {
                            if tab.state == .running {
                                SquareSpinner().frame(width: 9, height: 9).environment(\.squareOnSlab, isPicked)
                            }
                            Text(tab.name)
                            if tab.state == .failed {
                                Text("· failed").foregroundStyle(isPicked ? DesignTokens.Colors.onSlab : DesignTokens.Colors.diffRemove)
                            }
                        }
                        .font(Square.mono(12))
                        .foregroundStyle(isPicked ? DesignTokens.Colors.onSlab : DesignTokens.Colors.ink3)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(isPicked ? DesignTokens.Colors.slab : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 12)
                trailing()
            }
            content(picked)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(Rectangle().stroke(DesignTokens.Colors.ink, lineWidth: 1))
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
    /// Claude Code's session, which a click copies as a resume command.
    var sessionID: String?
    var stop: () -> Void = {}
    /// Offered on a failed run; nil offers nothing.
    var runAgain: (() -> Void)?

    /// Steps start open; the chevron folds them.
    @State private var stepsOpen = true

    private var steps: [SquareClaudeLine] {
        lines.filter { if case .call = $0 { true } else { false } }
    }

    private var said: [SquareClaudeLine] {
        lines.filter { if case .text = $0 { true } else if case .error = $0 { true } else { false } }
    }

    private var callCount: Int {
        lines.filter { if case .call = $0 { true } else { false } }.count
    }

    private var hasFooter: Bool {
        !footer.isEmpty || sessionID != nil || status == .running || status == .failed && runAgain != nil
    }

    /// Running with nothing back yet: the prompt's mark spins, as the pill's does.
    private var waiting: Bool {
        status == .running && lines.allSatisfy { if case .prompt = $0 { true } else { false } }
    }

    var body: some View {
        let open = stepsOpen
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    if case .prompt = line { row(line) }
                }
                if callCount > 0 || status == .running && !waiting {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { stepsOpen = !open } label: {
                            HStack(spacing: 6) {
                                SquareIcon("akar-chevron-down", size: 9).rotationEffect(.degrees(open ? 0 : -90))
                                Text(counted(callCount, "tool call")).font(Square.mono(12))
                                if status == .running { SquareClaudeSpinner() }
                            }
                            .foregroundStyle(DesignTokens.Colors.ink3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if open {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(steps.enumerated()), id: \.offset) { _, line in row(line) }
                            }
                            .padding(.leading, 15)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.Colors.inkA04)
            if !said.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(said.enumerated()), id: \.offset) { _, line in row(line) }
                }
            }
            if hasFooter {
                HStack(spacing: 8) {
                    if !footer.isEmpty { Text(footer).font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink3) }
                    if let sessionID {
                        // Reads as the rest of the footer; a click copies the resume command.
                        Text(footer.isEmpty ? sessionID : "· \(sessionID)")
                            .font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink3)
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
                    if status == .running {
                        Button("stop", action: stop).buttonStyle(SquareButtonStyle(kind: .quiet))
                    }
                    if status == .failed, let runAgain {
                        Button("run again", action: runAgain).buttonStyle(SquareButtonStyle(kind: .quiet))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
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
            SquareClaudeThread(lines: [.prompt("list each decision and who made it"), .meta("sonnet 5")], status: tab.state == .running ? .running : tab.state == .failed ? .failed : .done, footer: "4 s")
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
        }
    }
}

#Preview("tabs") { SquareTabsSpecimen().padding(24) }
#endif
