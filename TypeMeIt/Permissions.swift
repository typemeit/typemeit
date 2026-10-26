import AVFoundation
import ApplicationServices
import CoreGraphics
import Foundation

/// A grant the app cannot dictate without. Each is switched in System
/// Settings, so the app can only notice it has gone and point there.
enum MissingPermission: CaseIterable {
    case microphone, accessibility

    var name: String {
        switch self {
        case .microphone: "microphone"
        case .accessibility: "accessibility"
        }
    }

    /// What stops working without it.
    var consequence: String {
        switch self {
        case .microphone: "type me it can't record"
        case .accessibility: "type me it can't see the fn key or type where your cursor is"
        }
    }

    var settingsURL: URL {
        switch self {
        case .microphone: SecureInput.microphoneSettingsURL
        case .accessibility: SecureInput.accessibilitySettingsURL
        }
    }

    @MainActor var granted: Bool {
        switch self {
        case .microphone: MissingPermission.microphoneGranted
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// The microphone grant as last read. Each read is a TCC request, so it
    /// is read at launch, when the app comes to the front and at each
    /// dictation, not on the 1 s tick that reads the others.
    @MainActor private static var microphoneGranted = readMicrophone()

    private static func readMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    @MainActor static func refreshMicrophone() {
        microphoneGranted = readMicrophone()
    }

    /// The first permission that has been taken away, or nil when all hold.
    @MainActor static var first: MissingPermission? { allCases.first { !$0.granted } }
}
