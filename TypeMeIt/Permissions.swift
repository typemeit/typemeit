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

    var granted: Bool {
        switch self {
        case .microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility: AXIsProcessTrusted()
        }
    }

    /// The first permission that has been taken away, or nil when all hold.
    static var first: MissingPermission? { allCases.first { !$0.granted } }
}
