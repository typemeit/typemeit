import Foundation

/// Whether this process runs in the App Sandbox. The sandbox refuses the
/// Accessibility API on other apps whatever the user has granted, so
/// everything that reads another app's focused field or window title is off
/// while this is true, and the settings and pages built on it are not shown.
/// Posting key events still works, so pasting does.
enum Sandbox {
    static let isActive = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// The store build, or a dev build launched with `-previewStore 1` to
    /// look like it: for trying its shortcuts and capturing its screenshots.
    static let isStoreBuild = isActive || UserDefaults.standard.bool(forKey: "previewStore")

    /// Reading other apps through Accessibility: the focus check before a
    /// paste, the read-back that learns from corrections, window titles in
    /// history and the insights built on them.
    static var readsOtherApps: Bool { !isStoreBuild }

    /// The build is the App Store's: it links no Sparkle, so the update rows
    /// and the version row's install button have nothing to drive.
    static var updatesItself: Bool { !isStoreBuild }

    /// Fn alone is the dictation key. Seeing it takes a CGEvent tap, and App
    /// Review refuses a tap as Accessibility used for something other than
    /// accessibility (guideline 2.4.5), so the store build registers system
    /// hotkeys instead, which need no permission but cannot be a lone
    /// modifier.
    static var watchesFn: Bool { !isStoreBuild }

    /// Meetings: call detection, the room, the meetings page and its
    /// settings. The store build leaves them out until system-audio capture
    /// and the meetings folder are made to work in the sandbox.
    static var hasMeetings: Bool { !isStoreBuild }
}
