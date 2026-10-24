import AppKit
import SwiftUI

/// Adds the type me it camera for dev builds, which can't add it themselves
/// (Scripts/install-camera.sh); a release build of type me it adds its own
/// from its settings. `-remove` removes it.
@main
struct CameraHost: App {
    @State private var installer = CameraInstaller.shared

    var body: some Scene {
        Window("type me it camera", id: "camera") {
            CameraHostView(installer: installer)
                .task { CommandLine.arguments.contains("-remove") ? installer.remove() : installer.add() }
        }
        .windowResizability(.contentSize)
    }
}

struct CameraHostView: View {
    let installer: CameraInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if installer.status == .needsApproval {
                    Button("open system settings") { NSWorkspace.shared.open(CameraInstaller.loginItemsSettings) }
                }
                Spacer()
                Button("quit") { NSApp.terminate(nil) }
            }
        }
        .padding(22)
        .frame(width: 380)
    }

    private var title: String {
        switch installer.status {
        case .unknown, .notAdded, .adding: "installing the camera…"
        case .removing: "removing the camera…"
        case .needsApproval: "allow the camera"
        case .added: "camera installed"
        case .removed: "camera removed"
        case .failed: "the camera did not install"
        }
    }

    private var detail: String {
        switch installer.status {
        case .unknown, .notAdded, .adding: "type me it camera is asking macOS to add it."
        case .removing: "type me it camera is asking macOS to remove it."
        case .needsApproval: "In Login Items & Extensions, click ⓘ next to type me it camera and turn on Media Extension."
        case .added: "Pick type me it as the camera in your meeting app. type me it shows the real camera through it, and Claude's answers when you ask."
        case .removed: "type me it no longer shows as a camera."
        case .failed(let reason): reason
        }
    }
}
