import Foundation
import Observation
import Security
import SystemExtensions

/// Adds and removes the type me it camera, the system extension inside the
/// running app, and says where that stands. macOS adds a system extension
/// only for an app in /Applications that holds the system-extension.install
/// entitlement, and only once the user allows it in System Settings.
@MainActor @Observable
final class CameraInstaller: NSObject {
    enum Status: Equatable {
        /// Not asked about yet.
        case unknown
        case notAdded
        case adding
        case needsApproval
        case added
        case removing
        case removed
        case failed(String)
    }

    private enum Request { case add, remove, properties }

    static let shared = CameraInstaller()

    private(set) var status = Status.unknown
    /// The requests macOS has not answered yet, by request.
    private var pending: [ObjectIdentifier: Request] = [:]
    /// After `refresh`, add the camera again if the one macOS runs is older than this app's.
    private var updating = false

    static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    /// This build holds the entitlement adding the camera takes. Dev builds
    /// don't, and add it with Scripts/install-camera.sh.
    static let canAdd: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.system-extension.install" as CFString, nil) as? Bool == true
    }()

    static var inApplications: Bool { Bundle.main.bundleURL.path.hasPrefix("/Applications/") }

    /// The build number of the camera inside this app.
    private static var bundledVersion: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(CameraIDs.extensionID).systemextension")
        return Bundle(url: url)?.infoDictionary?["CFBundleVersion"] as? String
    }

    func add() {
        submit(.activationRequest(forExtensionWithIdentifier: CameraIDs.extensionID, queue: .main), as: .add)
    }

    func remove() {
        submit(.deactivationRequest(forExtensionWithIdentifier: CameraIDs.extensionID, queue: .main), as: .remove)
    }

    /// Asks macOS whether the camera is added or waiting to be allowed.
    /// With `update`, a camera older than this app's is replaced, which
    /// macOS does without asking again.
    func refresh(update: Bool) {
        guard Self.canAdd, pending.isEmpty else { return }
        updating = update
        submit(.propertiesRequest(forExtensionWithIdentifier: CameraIDs.extensionID, queue: .main), as: .properties)
    }

    private func submit(_ request: OSSystemExtensionRequest, as kind: Request) {
        pending[ObjectIdentifier(request)] = kind
        switch kind {
        case .add: status = .adding
        case .remove: status = .removing
        case .properties: break
        }
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
}

// The requests are submitted on the main queue, so they answer on it.
extension CameraInstaller: @preconcurrency OSSystemExtensionRequestDelegate {
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension replacement: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        status = .needsApproval
    }

    func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
        let live = properties.filter { !$0.isUninstalling }
        if let enabled = live.first(where: \.isEnabled) {
            status = .added
            if updating, let bundled = Self.bundledVersion, enabled.bundleVersion != bundled { add() }
        } else {
            status = live.contains(where: \.isAwaitingUserApproval) ? .needsApproval : .notAdded
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch pending.removeValue(forKey: ObjectIdentifier(request)) {
        case .add: status = .added
        case .remove: status = .removed
        case .properties, nil: break
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        if pending.removeValue(forKey: ObjectIdentifier(request)) != .properties { status = .failed(error.localizedDescription) }
    }
}
