import AppKit
import SwiftUI

/// The square parts: the redesign's controls, drawn square on hairlines, set
/// in mono where you act or count and in SF where you read. Sizes are the ones
/// the canvas's parts board draws; colours and motion come from DesignTokens.
enum Square {
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func sans(_ size: CGFloat) -> Font { .system(size: size) }

    /// The same two faces for AppKit, for the fields.
    static func appKitMono(_ size: CGFloat) -> NSFont { .monospacedSystemFont(ofSize: size, weight: .regular) }
    static func appKitSans(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size) }

    /// The label size on every control: buttons, segments, menus, keys, chips.
    static let controlSize: CGFloat = 12

    /// How far a mono label's letters sit below the middle of its line, from
    /// the face's own metrics. Lowercase centres on the x-height; capitals,
    /// digits and the modifier symbols centre on the cap height. The line box
    /// centres ascender to descender, so without this a lowercase label looks
    /// low in its box.
    static func drop(of text: String, size: CGFloat) -> CGFloat {
        drop(lowercase: text.contains(where: \.isLowercase), size: size)
    }

    static func drop(lowercase: Bool, size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let band = lowercase ? font.xHeight : font.capHeight
        return (font.ascender + font.descender - band) / 2
    }
}

/// An akar icon from the asset catalog, in the current foreground. Inside a
/// button's label it drops back by the lift the label's letters were given,
/// so it sits on the button's true centre.
struct SquareIcon: View {
    let name: String
    var size: CGFloat
    @Environment(\.squareLabelLift) private var lift

    init(_ name: String, size: CGFloat = 16) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(name).resizable().frame(width: size, height: size).offset(y: lift)
    }
}

/// A part's hairline edge; dashed, it says a recorder is listening.
enum SquareEdge {
    static let dash: [CGFloat] = [3, 2]
    /// How far a button's hard shadow reaches under the pointer, and how far
    /// the button travels onto it while held.
    static let shadowDepth: CGFloat = 2

    static func style(dashed: Bool) -> StrokeStyle {
        StrokeStyle(lineWidth: DesignTokens.hairline, dash: dashed ? dash : [])
    }
}

/// The pointer state a part is drawn in. Previews pin it, so every state can
/// be reviewed side by side; in the app it stays `.live` and the pointer
/// decides.
enum SquarePose: Sendable {
    case live, hover, pressed

    func hot(_ hovering: Bool) -> Bool {
        switch self {
        case .live: hovering
        case .hover, .pressed: true
        }
    }

    func down(_ pressed: Bool) -> Bool {
        switch self {
        case .live: pressed
        case .hover: false
        case .pressed: true
        }
    }
}

extension EnvironmentValues {
    @Entry var squarePose: SquarePose = .live
    /// Set by a slab surface (a failed prompt, the live band) so the parts on
    /// it invert: buttons fill with on-slab and crosses turn on-slab.
    @Entry var squareOnSlab = false
    /// How far a button lifted its label to centre its lowercase letters.
    @Entry var squareLabelLift: CGFloat = 0
}

/// The part of a hard shadow that shows from under a square: a strip down its
/// right side and one along its bottom, drawn outside the square's bounds.
struct SquareShadowShape: Shape {
    var depth = SquareEdge.shadowDepth

    func path(in rect: CGRect) -> Path {
        Path { p in
            p.addRect(CGRect(x: rect.maxX, y: rect.minY + depth, width: depth, height: rect.height))
            p.addRect(CGRect(x: rect.minX + depth, y: rect.maxY, width: rect.width - depth, height: depth))
        }
    }
}

extension View {
    /// A button's answer to the pointer: a hard shadow under it while hot,
    /// and the button pressed down onto it while held. Neither moves what is
    /// around it.
    func squarePress(hot: Bool, down: Bool, shadow: Color) -> some View {
        offset(x: down ? SquareEdge.shadowDepth : 0, y: down ? SquareEdge.shadowDepth : 0)
            .background { if hot, !down { SquareShadowShape().fill(shadow) } }
    }

    /// Lifts a boxed label so its letters, not its line, sit in the middle.
    func centredLetters(_ text: String, size: CGFloat = Square.controlSize) -> some View {
        offset(y: -Square.drop(of: text, size: size))
    }

    /// The same for a label whose text isn't to hand, such as a button's:
    /// labels are set lowercase throughout.
    func centredLowercase(size: CGFloat = Square.controlSize) -> some View {
        offset(y: -Square.drop(lowercase: true, size: size))
    }

    /// The one shadow, for what floats: the prompt, menus and popovers.
    func squareLift() -> some View { modifier(SquareLift()) }
}

/// Every part that floats is a rectangle, so the shadow is cast by a
/// rectangle behind it, one per layer of `shadow.lift`.
private struct SquareLift: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let layers = scheme == .dark ? DesignTokens.Shadow.liftDark : DesignTokens.Shadow.liftLight
        content.background {
            ZStack {
                ForEach(layers.indices, id: \.self) { i in
                    Rectangle()
                        .fill(DesignTokens.Colors.paper)
                        .shadow(color: layers[i].color, radius: layers[i].radius, x: layers[i].x, y: layers[i].y)
                }
            }
        }
    }
}

/// Paper with an ink hairline and the lift: what a menu, a popover or the
/// prompt floats on.
struct SquarePanel<Content: View>: View {
    var padding = EdgeInsets()
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(DesignTokens.Colors.paper)
            .overlay(Rectangle().strokeBorder(DesignTokens.Colors.ink, lineWidth: DesignTokens.hairline))
            .squareLift()
    }
}

#if DEBUG
extension SquarePose: CaseIterable {
    var name: String {
        switch self {
        case .live: "rest"
        case .hover: "hover"
        case .pressed: "held"
        }
    }
}

/// A part in each of its states, on light paper and on dark, the way the
/// canvas's parts board lays them out.
struct SquareSpecimen<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            sheet(.light)
            sheet(.dark)
        }
        .fixedSize()
    }

    private func sheet(_ scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(24)
            .background(DesignTokens.Colors.paper)
            .environment(\.colorScheme, scheme)
    }
}

/// One line of a specimen: the state's name, then the part drawn in it.
struct SquareSpecimenLine<Content: View>: View {
    let name: String
    var pose: SquarePose = .live
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 16) {
            Text(name)
                .font(Square.mono(11))
                .foregroundStyle(DesignTokens.Colors.ink3)
                .frame(width: 96, alignment: .leading)
            HStack(spacing: 10) { content }
                .environment(\.squarePose, pose)
        }
        .padding(.vertical, 12)
        .frame(minWidth: 360, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(DesignTokens.Colors.rule).frame(height: DesignTokens.hairline)
        }
    }
}
#endif
