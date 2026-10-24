import AVFoundation
import AppKit
import SwiftUI

/// Sets up the type me it camera when on camera is turned on: add it, allow
/// it in System Settings, let type me it use the real camera, then pick it
/// in a meeting app. A step moves on by itself once it is done. Closing the
/// sheet early leaves the rest to the on camera row, which says what is left.
struct CameraSetupView: View {
    var close: () -> Void

    enum Step: Int, CaseIterable { case add, allow, access, pick }

    @State private var step = CameraSetupView.firstStep()
    @State private var installer = CameraInstaller.shared
    @State private var feed = CameraFeed.shared
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("step \(step.rawValue + 1) of \(Step.allCases.count)")
                    .font(DesignTokens.Fonts.micro.monospaced())
                    .foregroundStyle(DesignTokens.Colors.ink3)
                Text(title)
                    .font(DesignTokens.Fonts.display3)
                    .tracking(DesignTokens.Tracking.display3)
                    .foregroundStyle(DesignTokens.Colors.ink)
                Text(explanation)
                    .font(DesignTokens.Fonts.body)
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
                .padding(.top, 24)
                .id(step)
                .transition(.opacity)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                StepDots(current: step.rawValue, count: Step.allCases.count)
                Spacer()
                if step != .pick {
                    Button("later", action: close).buttonStyle(InkButtonStyle(quiet: true))
                }
                Button(step == .pick ? "done" : "continue") { advance() }
                    .buttonStyle(InkButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canContinue)
            }
        }
        .padding(28)
        .frame(width: 520, height: 440)
        .background(DesignTokens.Colors.paper)
        .tint(DesignTokens.Colors.ink)
        .animation(.easeOut(duration: DesignTokens.Duration.n2), value: step)
        .onReceive(poll) { _ in access = AVCaptureDevice.authorizationStatus(for: .video) }
        .onChange(of: canContinue) { _, ok in if ok { advanceWhenSettled() } }
    }

    private var title: String {
        switch step {
        case .add: "add the camera"
        case .allow: "allow it"
        case .access: "camera access"
        case .pick: "pick it in your meeting"
        }
    }

    private var explanation: String {
        switch step {
        case .add: "type me it adds a camera called type me it. meeting apps list it next to your own."
        case .allow: "in system settings, click ⓘ next to type me it camera and turn on media extension."
        case .access: "type me it needs your camera to show you."
        case .pick: "choose type me it as the camera in meet, zoom or teams. while a meeting records, claude's cloud and answers show in your video."
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .add:
            SettingsGroup {
                SettingsRow(label: "type me it camera", last: true) { addControl }
            }
            if case .failed(let reason) = installer.status, !Self.added {
                Text(reason)
                    .font(DesignTokens.Fonts.micro)
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
        case .allow:
            VStack(alignment: .leading, spacing: 16) {
                SystemSettingsPicture()
                SettingsGroup {
                    SettingsRow(label: "media extension", last: true) {
                        if feed.installed {
                            Status("on", done: true)
                        } else {
                            Button("system settings") { NSWorkspace.shared.open(CameraInstaller.loginItemsSettings) }
                                .buttonStyle(InkButtonStyle(primary: true))
                        }
                    }
                }
            }
        case .access:
            SettingsGroup {
                SettingsRow(label: "camera", last: true) {
                    switch access {
                    case .authorized:
                        Status("granted", done: true)
                    case .notDetermined:
                        Button("grant") {
                            Task { _ = await AVCaptureDevice.requestAccess(for: .video); access = AVCaptureDevice.authorizationStatus(for: .video) }
                        }
                        .buttonStyle(InkButtonStyle(primary: true))
                    default:
                        Button("system settings") { NSWorkspace.shared.open(SecureInput.cameraSettingsURL) }
                            .buttonStyle(InkButtonStyle(primary: true))
                    }
                }
            }
        case .pick:
            SettingsGroup {
                SettingsRow(label: "meeting app", last: true) {
                    if feed.watched { Status("showing type me it", done: true) } else { Status("not showing it yet") }
                }
            }
        }
    }

    @ViewBuilder private var addControl: some View {
        if Self.added {
            Status("added", done: true)
        } else if !CameraInstaller.canAdd {
            Status("dev build: scripts/install-camera.sh")
        } else if !CameraInstaller.inApplications {
            Status("move type me it to applications first")
        } else if installer.status == .adding {
            Status("adding…")
        } else {
            Button(installer.status == .unknown || installer.status == .notAdded ? "add" : "try again") { installer.add() }
                .buttonStyle(InkButtonStyle(primary: true))
        }
    }

    /// Added, though perhaps not allowed yet.
    private static var added: Bool {
        CameraFeed.shared.installed || [.needsApproval, .added].contains(CameraInstaller.shared.status)
    }

    private static func satisfied(_ step: Step) -> Bool {
        switch step {
        case .add: added
        case .allow: CameraFeed.shared.installed
        case .access: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        // Nothing to wait for: a meeting may be hours away.
        case .pick: true
        }
    }

    private var canContinue: Bool { Self.satisfied(step) }

    private static func firstStep() -> Step {
        // `-cameraSetupStep allow` opens on that step, for looking at one this Mac is past.
        if let name = UserDefaults.standard.string(forKey: "cameraSetupStep"),
           let step = Step.allCases.first(where: { "\($0)" == name }) { return step }
        return Step.allCases.first { !satisfied($0) } ?? .pick
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return close() }
        step = next
    }

    /// A step whose requirement was just met moves on by itself, after a beat
    /// long enough to read the check.
    private func advanceWhenSettled() {
        let current = step
        guard current != .pick else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(DesignTokens.Duration.n4))
            if step == current, canContinue { advance() }
        }
    }
}

/// The System Settings sheet the allow step points at: type me it camera's
/// extensions, its Media Extension switch on and ringed.
private struct SystemSettingsPicture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.25)).frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("type me it camera Extensions").font(.system(size: 12, weight: .semibold))
                    Text("1 extension installed").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "video").font(.system(size: 13)).frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Media Extension").font(.system(size: 12))
                    Text("Provides additional functionality for media applications").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                // Drawn, not a Toggle, so it reads as a picture rather than a switch here.
                Capsule().fill(Color.accentColor)
                    .frame(width: 30, height: 17)
                    .overlay(alignment: .trailing) { Circle().fill(.white).padding(2) }
                    .padding(4)
                    .overlay(Capsule().strokeBorder(DesignTokens.Colors.ink, lineWidth: 1.5))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.secondary.opacity(0.25), lineWidth: DesignTokens.hairline))
        .accessibilityHidden(true)
    }
}
