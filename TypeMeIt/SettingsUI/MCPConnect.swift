import SwiftUI

/// What an assistant needs to read the meetings: a command or a config entry
/// naming this build's own `typemeit-mcp`. Nothing here edits another app's
/// files; the user runs or pastes it.
enum MCPSetup {
    enum Assistant: String, CaseIterable {
        case claudeCode = "claude code"
        case claudeDesktop = "claude desktop"
    }

    /// The bundled binary, at this build's own path, so the dev app copies its own.
    static let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/typemeit-mcp")
    /// Gatekeeper runs a quarantined app from a random path that is gone on
    /// the next launch, so a command naming it would break (docs/meetings.md 7.15).
    static let translocated = Bundle.main.bundlePath.contains("/AppTranslocation/")

    static func snippet(for assistant: Assistant) -> String {
        switch assistant {
        case .claudeCode: "claude mcp add --scope user typemeit -- \"\(binary.path)\""
        case .claudeDesktop: desktopEntry
        }
    }

    static func hint(for assistant: Assistant) -> String {
        switch assistant {
        case .claudeCode: "run it in a terminal"
        case .claudeDesktop: "paste it into claude_desktop_config.json, then restart claude desktop"
        }
    }

    /// The `mcpServers` entry for Claude Desktop's config file.
    private static var desktopEntry: String {
        let entry = ["mcpServers": ["typemeit": ["command": binary.path, "args": [String]()]]]
        let data = (try? JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// "connect an assistant", opening the panel under it.
struct MCPConnect: View {
    @State private var open = false

    var body: some View {
        SquareLink(title: "connect an assistant", size: 12) { open.toggle() }
            .squarePopover(isPresented: $open) { MCPConnectPanel { open = false } }
    }
}

/// Which assistant, exactly what gets copied, the copy button, and where to
/// put it.
struct MCPConnectPanel: View {
    let close: () -> Void
    @State private var assistant = MCPSetup.Assistant.claudeCode
    @State private var copied = false

    /// The panel's width inside its padding: the desktop entry's longest
    /// line, a build path, wraps rather than widening the panel.
    private static let width: CGFloat = 428

    var body: some View {
        SquarePanel(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SquareChoice(selection: $assistant, options: MCPSetup.Assistant.allCases) { $0.rawValue }
                    Spacer()
                    Button(action: close) { SquareIcon("akar-cross", size: 8) }
                        .buttonStyle(SquareIconButtonStyle(side: 22))
                        .help("close")
                        .accessibilityLabel("close")
                }
                Text(MCPSetup.snippet(for: assistant))
                    .font(Square.mono(11))
                    .lineSpacing(4)
                    .foregroundStyle(DesignTokens.Colors.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(DesignTokens.Colors.inkA04)
                HStack(spacing: 12) {
                    Text(MCPSetup.hint(for: assistant))
                        .font(Square.sans(11.5))
                        .foregroundStyle(DesignTokens.Colors.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Output.copyToClipboard(MCPSetup.snippet(for: assistant))
                        copied = true
                    } label: {
                        Label {
                            Text(copied ? "copied" : "copy")
                        } icon: {
                            SquareIcon(copied ? "akar-check" : "akar-copy", size: 12)
                        }
                    }
                    .buttonStyle(SquareButtonStyle(kind: .primary))
                }
            }
            .frame(width: MCPConnectPanel.width)
        }
        .onChange(of: assistant) { copied = false }
    }
}
