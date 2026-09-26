import AppKit
import SwiftUI

extension View {
    /// Floats `content` under this view on a borderless panel, centred on
    /// it and kept inside the window. Every popup opens this way, menus and
    /// questions alike. SwiftUI's own popover draws a rounded bubble with an
    /// arrow, which the square parts have no place for. A click outside the
    /// panel or esc closes it.
    func squarePopover<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background {
            if isPresented.wrappedValue {
                SquarePopoverAnchor(isPresented: isPresented, content: content)
            }
        }
    }
}

private struct SquarePopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> Content

    func makeNSView(context: Context) -> SquarePopoverAnchorView { SquarePopoverAnchorView() }

    func updateNSView(_ anchor: SquarePopoverAnchorView, context: Context) {
        let coordinator = context.coordinator
        let scheme = context.environment.colorScheme
        coordinator.dismiss = { isPresented = false }
        let root = AnyView(content().environment(\.colorScheme, scheme))
        anchor.place = { [weak anchor] in
            guard let anchor, anchor.window != nil else { return }
            coordinator.show(root, under: anchor, scheme: scheme)
        }
        anchor.place?()
    }

    func makeCoordinator() -> SquarePopoverController { SquarePopoverController() }

    static func dismantleNSView(_ anchor: SquarePopoverAnchorView, coordinator: SquarePopoverController) {
        coordinator.close()
    }
}

/// Marks where the popover hangs from while it is open. It sits behind the
/// view it belongs to, never takes a click from it, and places the panel
/// again whenever it lands in a window or moves.
final class SquarePopoverAnchorView: NSView {
    var place: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        place?()
    }

    override func setFrameOrigin(_ newOrigin: NSPoint) {
        super.setFrameOrigin(newOrigin)
        place?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class SquarePopoverController {
    var dismiss: () -> Void = {}
    private var panel: SquarePopoverPanel?
    private var host: NSHostingView<AnyView>?
    private var monitor: Any?

    /// Room round the panel for the lift, which a borderless window would
    /// otherwise cut off at its edge.
    private static let margin: CGFloat = 28
    /// The canvas's popups open this far below what they belong to.
    private static let gap: CGFloat = 4
    /// A popup under something near the window's side shifts along to stay
    /// this far inside it.
    private static let inset: CGFloat = 12

    func show(_ root: AnyView, under anchor: NSView, scheme: ColorScheme) {
        guard let window = anchor.window else { return }
        let padded = AnyView(root.padding(SquarePopoverController.margin))
        if let host {
            host.rootView = padded
        } else {
            let host = NSHostingView(rootView: padded)
            let panel = SquarePopoverPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.contentView = host
            window.addChildWindow(panel, ordered: .above)
            self.host = host
            self.panel = panel
            watch(anchor)
        }
        guard let host, let panel else { return }
        panel.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        let below = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let margin = SquarePopoverController.margin
        let inset = SquarePopoverController.inset
        let leftmost = window.frame.minX + inset - margin
        let rightmost = max(leftmost, window.frame.maxX - inset + margin - size.width)
        let x = min(max(below.midX - size.width / 2, leftmost), rightmost)
        let y = below.minY - SquarePopoverController.gap - size.height + margin
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let panel { panel.parent?.removeChildWindow(panel) }
        panel?.orderOut(nil)
        panel = nil
        host = nil
    }

    /// A click outside the panel closes it, except on the view it hangs from,
    /// whose own click decides; esc closes it too.
    private func watch(_ anchor: NSView) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self, weak anchor] event in
            guard let self else { return event }
            if event.type == .keyDown {
                guard event.keyCode == 53 else { return event }  // esc
                self.dismiss()
                return nil
            }
            if event.window === self.panel { return event }
            if let anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) {
                return event
            }
            self.dismiss()
            return event
        }
    }
}

/// Borderless panels refuse key by default; this one takes it, so a field on
/// it (a menu's search, the time of day) can be typed in.
private final class SquarePopoverPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
