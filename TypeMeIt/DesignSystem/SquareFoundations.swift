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
        Sample(text: "history", size: 14, weight: .medium, use: "the sidebar"),
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
    static var parts: [(name: String, view: AnyView)] {
        [
            ("colour", AnyView(SquareColourSpecimen())),
            ("type", AnyView(SquareTypeSpecimen())),
            ("weight", AnyView(SquareWeightSpecimen())),
            ("cloud palette", AnyView(SquareCloudPaletteSpecimen())),
            ("button", AnyView(SquareButtonSpecimen())),
            ("button hovers", AnyView(SquareButtonHoverSpecimen())),
            ("icon button", AnyView(SquareIconButtonSpecimen())),
            ("switch", AnyView(SquareSwitchSpecimen())),
            ("tick", AnyView(SquareTickSpecimen())),
            ("choice", AnyView(SquareChoiceSpecimen())),
            ("menu", AnyView(SquareMenuSpecimen())),
            ("filter", AnyView(SquareFilterSpecimen())),
            ("when", AnyView(SquareWhenSpecimen())),
            ("key", AnyView(SquareKeySpecimen())),
            ("recorder", AnyView(SquareRecorderSpecimen())),
            ("chip", AnyView(SquareChipSpecimen())),
            ("field", AnyView(SquareFieldSpecimen())),
            ("settings row", AnyView(SquareSettingsRowSpecimen())),
            ("group", AnyView(SquareGroupSpecimen())),
            ("list row", AnyView(SquareListRowSpecimen())),
            ("status", AnyView(SquareStatusSpecimen())),
            ("sidebar", AnyView(SquareSidebarSpecimen())),
            ("page header", AnyView(SquarePageHeaderSpecimen())),
            ("prompt", AnyView(SquarePromptSpecimen())),
            ("confirm and help", AnyView(SquareConfirmSpecimen())),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ForEach(SquareGallery.parts, id: \.name) { part in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(part.name).font(Square.mono(12, weight: .medium)).foregroundStyle(DesignTokens.Colors.ink)
                        part.view
                    }
                }
            }
            .padding(24)
        }
        .background(DesignTokens.Colors.paperSunk)
    }
}

#Preview("colour") { SquareColourSpecimen() }
#Preview("type") { SquareTypeSpecimen() }
#Preview("weight") { SquareWeightSpecimen() }
#Preview("everything") { SquareGallery().frame(width: 1320, height: 900) }
#endif
