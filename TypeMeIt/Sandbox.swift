import Foundation

/// Whether this process runs in the App Sandbox. The sandbox refuses the
/// Accessibility API on other apps whatever the user has granted, so
/// everything that reads another app's focused field or window title is off
/// while this is true, and the settings and pages built on it are not shown.
/// Posting key events still works, so pasting does.
enum Sandbox {
    static let isActive = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Reading other apps through Accessibility: the focus check before a
    /// paste, the read-back that learns from corrections, window titles in
    /// history and the insights built on them.
    static var readsOtherApps: Bool { !isActive }
}
