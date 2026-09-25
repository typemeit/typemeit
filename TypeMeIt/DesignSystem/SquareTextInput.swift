import AppKit
import SwiftUI

/// The editable line inside a square field. SwiftUI's own field lifts its
/// text half a point when it takes focus, so the placeholder jumps, and it
/// reports focus a beat late. A plain AppKit field keeps its text still and
/// says it has focus the moment it does.
struct SquareTextInput: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let font: NSFont
    @Binding var focused: Bool
    var onSubmit: () -> Void = {}
    /// Esc; nil leaves esc to the view around the field.
    var onCancel: (() -> Void)?

    func makeNSView(context: Context) -> SquareNSTextField {
        let field = SquareNSTextField()
        field.delegate = context.coordinator
        field.focusChanged = { [weak coordinator = context.coordinator] on in coordinator?.focusChanged(on) }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: SquareNSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.font = font
        field.textColor = NSColor(DesignTokens.Colors.ink)
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font,
            .foregroundColor: NSColor(DesignTokens.Colors.ink3),
        ])
        if focused, field.currentEditor() == nil, let window = field.window {
            window.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SquareTextInput

        init(_ parent: SquareTextInput) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)), let cancel = parent.onCancel {
                cancel()
                return true
            }
            return false
        }

        func focusChanged(_ on: Bool) {
            if parent.focused != on { parent.focused = on }
        }
    }
}

final class SquareNSTextField: NSTextField {
    var focusChanged: (Bool) -> Void = { _ in }

    init() {
        super.init(frame: .zero)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { focusChanged(true) }
        return took
    }

    override func textDidEndEditing(_ notification: Notification) {
        super.textDidEndEditing(notification)
        focusChanged(false)
    }
}
