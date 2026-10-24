import AppKit
import SwiftUI

/// Inline Markdown whose links behave like the app's link buttons: a faint
/// underline that goes full colour under the pointer, with the hand cursor.
/// SwiftUI's `Text` cannot hover a single run, so this is a text view.
struct LinkText: NSViewRepresentable {
    let markdown: String
    let font: NSFont
    let color: NSColor
    var lineSpacing: CGFloat = 0

    func makeNSView(context: Context) -> LinkTextView {
        let view = LinkTextView()
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.linkTextAttributes = [:]
        return view
    }

    func updateNSView(_ view: LinkTextView, context: Context) {
        view.color = color
        let styled = styled()
        if view.attributedString() != styled {
            view.textStorage?.setAttributedString(styled)
            view.hovered = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: LinkTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let container = view.textContainer, let layout = view.layoutManager else { return nil }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    private func styled() -> NSAttributedString {
        let parsed = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        let styled = NSMutableAttributedString()
        for run in parsed.runs {
            var runFont = font
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { runFont = .monospacedSystemFont(ofSize: font.pointSize, weight: .regular) }
            if intent.contains(.stronglyEmphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { runFont = NSFontManager.shared.convert(runFont, toHaveTrait: .italicFontMask) }
            var attributes: [NSAttributedString.Key: Any] = [.font: runFont, .foregroundColor: color, .paragraphStyle: paragraph]
            if let link = run.link {
                attributes[.link] = link
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = LinkTextView.restingUnderline(color)
            }
            styled.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return styled
    }
}

final class LinkTextView: NSTextView {
    var color: NSColor = .labelColor

    /// The text's own colour, faint, so links rest the same on the slab and on paper.
    static func restingUnderline(_ color: NSColor) -> NSColor { color.withAlphaComponent(color.alphaComponent * 0.36) }
    /// The link under the pointer, underlined in full colour.
    var hovered: NSRange? {
        didSet {
            guard hovered != oldValue, let storage = textStorage else { return }
            if let oldValue, NSMaxRange(oldValue) <= storage.length {
                storage.addAttribute(.underlineColor, value: Self.restingUnderline(color), range: oldValue)
            }
            if let hovered { storage.addAttribute(.underlineColor, value: color, range: hovered) }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self && area.userInfo?["links"] != nil { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: ["links": true]))
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        hovered = linkRange(at: convert(event.locationInWindow, from: nil))
        (hovered == nil ? NSCursor.iBeam : NSCursor.pointingHand).set()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hovered = nil
    }

    private func linkRange(at point: NSPoint) -> NSRange? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        var fraction: CGFloat = 0
        let index = layout.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: &fraction)
        let glyph = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil), in: container)
        guard index < storage.length, glyph.contains(point) else { return nil }
        var range = NSRange()
        return storage.attribute(.link, at: index, effectiveRange: &range) == nil ? nil : range
    }
}
