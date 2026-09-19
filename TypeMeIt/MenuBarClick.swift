import AppKit

/// An Option-click on the menu bar puff starts a recording, or stops the one
/// in progress, without opening the menu. `MenuBarExtra` has no click
/// handler of its own, so the click is caught on its way to the status
/// item's button.
@MainActor
enum MenuBarClick {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.modifierFlags.contains(.option), isOnStatusItem(event) else { return event }
            // With nothing to start or stop, the click opens the menu as usual.
            return Pipeline.shared.shortcuts.toggleFromMenuBar() ? nil : event
        }
    }

    /// The status item's window holds nothing but its button, so a click in
    /// that window is a click on the puff.
    private static func isOnStatusItem(_ event: NSEvent) -> Bool {
        guard let content = event.window?.contentView else { return false }
        return holdsStatusBarButton(content)
    }

    private static func holdsStatusBarButton(_ view: NSView) -> Bool {
        view is NSStatusBarButton || view.subviews.contains(where: holdsStatusBarButton)
    }
}
