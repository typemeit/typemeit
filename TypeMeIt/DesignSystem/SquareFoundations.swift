#if DEBUG
import AppKit
import SwiftUI

/// One ink and one paper, with the washes between them and the two diff
/// colours. Each swatch prints the value it resolves to in that appearance.
struct SquareColourSpecimen: View {
    private let greys: [(String, Color)] = [
        ("paper", DesignTokens.Colors.paper), ("paper-sunk", DesignTokens.Colors.paperSunk),
        ("rule", DesignTokens.Colors.rule), ("rule-control", DesignTokens.Colors.ruleControl),
        ("ink-3", DesignTokens.Colors.ink3), ("ink-2", DesignTokens.Colors.ink2), ("ink", DesignTokens.Colors.ink),
    ]
    private let washes: [(String, Color)] = [
        ("ink-a04", DesignTokens.Colors.inkA04), ("ink-a08", DesignTokens.Colors.inkA08), ("ink-a12", DesignTokens.Colors.inkA12),
        ("ink-a20", DesignTokens.Colors.inkA20), ("ink-a32", DesignTokens.Colors.inkA32), ("ink-a64", DesignTokens.Colors.inkA64),
        ("diff-add", DesignTokens.Colors.diffAdd), ("diff-remove", DesignTokens.Colors.diffRemove),
    ]

    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "one ink, one paper") { row(greys) }
            SquareSpecimenLine(name: "washes, diff") { row(washes) }
        }
    }

    private func row(_ swatches: [(String, Color)]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(swatches, id: \.0) { name, color in SquareSwatch(name: name, color: color) }
        }
    }
}

private struct SquareSwatch: View {
    let name: String
    let color: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: 52, height: 44)
                .overlay(Rectangle().strokeBorder(DesignTokens.Colors.rule, lineWidth: DesignTokens.hairline))
            Text(name).foregroundStyle(DesignTokens.Colors.ink2)
            Text(value).foregroundStyle(DesignTokens.Colors.ink3)
        }
        .font(Square.mono(10))
        .frame(width: 60, alignment: .leading)
    }

    /// The colour as it resolves under this appearance, as hex and opacity.
    private var value: String {
        var out = ""
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
            let hex = [c.redComponent, c.greenComponent, c.blueComponent].map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
            out = c.alphaComponent < 1 ? "#\(hex) \(Int((c.alphaComponent * 100).rounded()))%" : "#\(hex)"
        }
        return out
    }
}

/// Mono where you act or count, SF where you read. Each line is labelled
/// from the same numbers it is set in.
struct SquareTypeSpecimen: View {
    private struct Sample {
        let text: String
        let size: CGFloat
        var weight: Font.Weight = .regular
        var mono = true
        let use: String
    }

    private let samples: [Sample] = [
        Sample(text: "meetings", size: 40, use: "page titles"),
        Sample(text: "pricing page review", size: 30, use: "a meeting, a section"),
        Sample(text: "pricing page review", size: 20, weight: .medium, use: "a page inside a page"),
        Sample(text: "keeping three tiers. ana rewrites the team plan copy by friday.", size: 15, mono: false, use: "anything you read"),
        Sample(text: "dictations", size: 14, weight: .medium, use: "the sidebar"),
        Sample(text: "copy last transcript", size: 13, use: "row labels"),
        Sample(text: "show · stop · record", size: 12, use: "controls"),
        Sample(text: "11m · slack · ana, tom, you", size: 11, use: "labels and metadata"),
        Sample(text: "reads a few pixels under the cloud", size: 11.5, mono: false, use: "captions"),
    ]

    var body: some View {
        SquareSpecimen {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(samples.indices, id: \.self) { i in
                    let s = samples[i]
                    VStack(alignment: .leading, spacing: 6) {
                        Text(s.text)
                            .font(s.mono ? Square.mono(s.size, weight: s.weight) : Square.sans(s.size))
                            .foregroundStyle(DesignTokens.Colors.ink)
                        Text("\(s.mono ? "sf mono" : "sf pro") \(s.size.formatted())\(s.weight == .medium ? " medium" : "") · \(s.use)")
                            .font(Square.mono(11))
                            .foregroundStyle(DesignTokens.Colors.ink3)
                    }
                }
            }
            .frame(width: 520, alignment: .leading)
        }
    }
}

/// Weight comes from rules, the slab and the wash, never from boxes.
struct SquareWeightSpecimen: View {
    var body: some View {
        SquareSpecimen {
            SquareSpecimenLine(name: "ink rule") { mark(Rectangle().fill(DesignTokens.Colors.ink).frame(height: DesignTokens.hairline), "a new day, the player") }
            SquareSpecimenLine(name: "hairline") { mark(Rectangle().fill(DesignTokens.Colors.rule).frame(height: DesignTokens.hairline), "between rows") }
            SquareSpecimenLine(name: "slab") { mark(Rectangle().fill(DesignTokens.Colors.slab).frame(height: 14), "selected, primary, live") }
            SquareSpecimenLine(name: "wash") { mark(Rectangle().fill(DesignTokens.Colors.inkA04).frame(height: 14), "hover") }
            SquareSpecimenLine(name: "lift") {
                SquarePanel { Color.clear.frame(width: 44, height: 22) }
                Text("the prompt, menus and popovers: the only shadow").font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
            }
        }
    }

    private func mark(_ sample: some View, _ use: String) -> some View {
        HStack(spacing: 10) {
            sample.frame(width: 44)
            Text(use).font(Square.mono(11)).foregroundStyle(DesignTokens.Colors.ink2)
        }
    }
}

/// Every part on one sheet, in the order the canvas's parts board runs.
struct SquareGallery: View {
    typealias Part = (name: String, also: String, view: AnyView)

    private enum Appearance: String, CaseIterable {
        case auto, light, dark

        var scheme: ColorScheme? {
            switch self {
            case .auto: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// `also` holds the other words someone might search for the part by.
    static var parts: [Part] {
        [
            ("colour", "color ink paper token grey diff", AnyView(SquareColourSpecimen())),
            ("type", "font text typography", AnyView(SquareTypeSpecimen())),
            ("weight", "font bold", AnyView(SquareWeightSpecimen())),
            ("cloud palette", "color puff tint", AnyView(SquareCloudPaletteSpecimen())),
            ("button", "action cta", AnyView(SquareButtonSpecimen())),
            ("icon button", "glyph symbol", AnyView(SquareIconButtonSpecimen())),
            ("switch", "toggle on off", AnyView(SquareSwitchSpecimen())),
            ("tick", "checkbox check", AnyView(SquareTickSpecimen())),
            ("choice", "radio segmented picker option", AnyView(SquareChoiceSpecimen())),
            ("screen", "display monitor picker", AnyView(SquareScreenPickerSpecimen())),
            ("menu", "dropdown select popup", AnyView(SquareMenuSpecimen())),
            ("filter", "search narrow", AnyView(SquareFilterSpecimen())),
            ("when", "date time range", AnyView(SquareWhenSpecimen())),
            ("key", "keycap shortcut hotkey", AnyView(SquareKeySpecimen())),
            ("recorder", "shortcut hotkey keycap", AnyView(SquareRecorderSpecimen())),
            ("chip", "tag pill token", AnyView(SquareChipSpecimen())),
            ("field", "input text search", AnyView(SquareFieldSpecimen())),
            ("settings row", "preference help caption", AnyView(SquareSettingsRowSpecimen())),
            ("group", "section card", AnyView(SquareGroupSpecimen())),
            ("box", "container panel card", AnyView(SquareBoxSpecimen())),
            ("stat", "number metric insight", AnyView(SquareStatSpecimen())),
            ("player", "audio playback scrub", AnyView(SquarePlayerSpecimen())),
            ("fingerprint", "meeting speakers who spoke when grid", AnyView(SquareFingerprintSpecimen())),
            ("layouts", "grid page split", AnyView(SquareLayoutsSpecimen())),
            ("list head", "table header column", AnyView(SquareListHeadSpecimen())),
            ("status", "state progress badge", AnyView(SquareStatusSpecimen())),
            ("sidebar", "navigation nav", AnyView(SquareSidebarSpecimen())),
            ("page header", "title toolbar", AnyView(SquarePageHeaderSpecimen())),
            ("prompt", "input ask composer", AnyView(SquarePromptSpecimen())),
            ("tabs", "navigation segmented", AnyView(SquareTabsSpecimen())),
            ("claude output", "markdown thread ai stream", AnyView(SquareClaudeThreadSpecimen())),
            ("confirm and help", "alert dialog popover tooltip", AnyView(SquareConfirmSpecimen())),
        ]
    }

    /// `-part prompt` on the command line opens the gallery on that part alone.
    private static let only = UserDefaults.standard.string(forKey: "part")
    @State private var query = ""
    @State private var selectedPart: String?
    @AppStorage("appearance") private var appearance = Appearance.auto

    private var shown: [Part] {
        SquareGallery.parts.filter { part in
            (SquareGallery.only == nil || part.name == SquareGallery.only)
                && (query.isEmpty || part.name.localizedCaseInsensitiveContains(query)
                    || part.also.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        let matchingParts = shown
        NavigationSplitView {
            List(matchingParts, id: \.name, selection: $selectedPart) { part in
                Text(part.name).font(Square.mono(12))
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        ForEach(matchingParts, id: \.name) { part in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(part.name).font(Square.mono(12, weight: .medium)).foregroundStyle(DesignTokens.Colors.ink)
                                part.view
                            }
                            .id(part.name)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
                .onChange(of: selectedPart) { _, part in
                    guard let part else { return }
                    withAnimation(.easeOut(duration: 0.2)) { scroller.scrollTo(part, anchor: .top) }
                }
            }
            .background(DesignTokens.Colors.paperSunk)
            .overlay {
                if matchingParts.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle(counted(matchingParts.count, "part"))
            .toolbar {
                Picker("appearance", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "parts")
        .preferredColorScheme(appearance.scheme)
    }
}

#Preview("colour") { SquareColourSpecimen() }
#Preview("type") { SquareTypeSpecimen() }
#Preview("weight") { SquareWeightSpecimen() }
#Preview("everything") { SquareGallery().frame(width: 1320, height: 900) }
#endif
