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
    /// Any other editing command (arrows, tab); true when it was handled.
    var onCommand: ((Selector) -> Bool)?

    func makeNSView(context: Context) -> SquareNSTextField {
        let field = SquareNSTextField()
        field.delegate = context.coordinator
        field.focusChanged = { [weak coordinator = context.coordinator] on in coordinator?.focusChanged(on) }
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The ink tokens are dynamic colours, resolved each time the field draws.
        field.textColor = NSColor(DesignTokens.Colors.ink)
        return field
    }

    /// Sets only what changed: a new font or placeholder makes the field
    /// measure itself again, and SwiftUI updates the field each time it
    /// redraws anything around it.
    func updateNSView(_ field: SquareNSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if field.font != font || context.coordinator.shownPlaceholder != placeholder {
            field.font = font
            field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: font,
                .foregroundColor: NSColor(DesignTokens.Colors.ink3),
            ])
            context.coordinator.shownPlaceholder = placeholder
        }
        // Focus is taken once when asked for: a field that asked on every
        // update would take first responder from whichever field had it
        // each time SwiftUI updated the page.
        if focused != context.coordinator.askedFocus {
            context.coordinator.askedFocus = focused
            if focused { field.takeFocus() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SquareTextInput
        /// `focused` as of the last update, so a request is acted on once.
        var askedFocus = false
        var shownPlaceholder: String?

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
            return parent.onCommand?(selector) ?? false
        }

        func focusChanged(_ on: Bool) {
            if parent.focused != on { parent.focused = on }
        }
    }
}

final class SquareNSTextField: NSTextField {
    var focusChanged: (Bool) -> Void = { _ in }
    /// Focus asked for before the field was in a window.
    private var focusOnWindow = false

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

    /// Makes the field first responder, or does once it is in a window. A
    /// refusal reports focus as lost, after the update that asked, so the
    /// next request is a new one.
    func takeFocus() {
        guard currentEditor() == nil else { return }
        guard let window else { focusOnWindow = true; return }
        if !window.makeFirstResponder(self) {
            DispatchQueue.main.async { [weak self] in self?.focusChanged(false) }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnWindow, window != nil else { return }
        focusOnWindow = false
        takeFocus()
    }

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
