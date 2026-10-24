import AppKit
import SwiftUI

/// Borderless, non-activating panel at the bottom centre of the screen with
/// the mouse, at its top centre, or against its left or right edge halfway
/// up. The transparent 460 x 460 window sits on the bottom edge of
/// the visible screen, so the cloud has room to swell and the pill can
/// change width, open an answer and cast a shadow without the window
/// resizing.
@MainActor
final class OverlayPanel {
    let model = OverlayModel()
    private let panel: UnconstrainedPanel
    /// The pill's frame in the panel's SwiftUI coordinates, origin top left.
    private var pillFrame: CGRect = .zero

    static let size = NSSize(width: 460, height: 460)
    /// How far the cloud's centre sits in from the screen edge at a side.
    static let sideInset: CGFloat = 56
    /// The same at the top, measured from the screen's own top edge rather
    /// than the visible frame's, so the cloud sits over the menu bar rather
    /// than under it. The panel is above the menu bar's level.
    static let topInset: CGFloat = 76

    init() {
        panel = UnconstrainedPanel(contentRect: NSRect(origin: .zero, size: OverlayPanel.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: OverlayRoot(model: model) { [weak self] frame in
            self?.pillFrame = frame
            self?.updateClickThrough()
        })
        host.frame = NSRect(origin: .zero, size: OverlayPanel.size)
        panel.contentView = host
        panel.alphaValue = 0
        // The first frame of the puff would otherwise wait for its shader to
        // compile, and the arrival is over in about a second.
        Task { try? await PuffView.compileShader() }
        // The global monitor sees the mouse over other apps' windows, the
        // local one over the panel while it takes clicks.
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateClickThrough() }
        }
        NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            MainActor.assumeIsolated { self?.updateClickThrough() }
            return event
        }
    }

    /// The panel covers 460 x 460, far more than the cloud or pill drawn in
    /// it, so it takes clicks only while the mouse is over one of them and
    /// lets the rest through to the windows behind. The cloud takes them
    /// while Fn is held, to pin, and once pinned, to finish; before the
    /// microphone has opened there is nothing to click.
    private func updateClickThrough() {
        guard panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let takesClicks = switch model.presentation {
        case .cloud: (model.state == .recording || model.state == .pinned) && cloudRect.contains(mouse)
        case .pill: pillRect.contains(mouse)
        case .none: false
        }
        if panel.ignoresMouseEvents == takesClicks { panel.ignoresMouseEvents = !takesClicks }
    }

    /// The pill, in screen coordinates.
    private var pillRect: NSRect {
        NSRect(x: panel.frame.minX + pillFrame.minX, y: panel.frame.maxY - pillFrame.maxY,
               width: pillFrame.width, height: pillFrame.height)
    }

    /// The presentation the panel was last placed for. The cloud may sit at
    /// a side; the pill is always at the bottom centre, so a switch between
    /// them moves the panel.
    private var placedFor: OverlayModel.Presentation?

    private func reposition() {
        placedFor = model.presentation
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        // The cloud's centre is half the panel across and restHeight up, so
        // at a side or the top the panel hangs partly off the screen to put
        // the cloud against the edge.
        let half = OverlayPanel.size.width / 2
        let position = model.presentation == .cloud ? Settings.shared.cloudPosition : .centre
        let origin: NSPoint = switch position {
        case .left: NSPoint(x: visible.minX + OverlayPanel.sideInset - half, y: visible.midY - CloudView.restHeight)
        case .top: NSPoint(x: visible.midX - half, y: screen.frame.maxY - OverlayPanel.topInset - CloudView.restHeight)
        case .centre: NSPoint(x: visible.midX - half, y: visible.minY)
        case .right: NSPoint(x: visible.maxX - OverlayPanel.sideInset - half, y: visible.midY - CloudView.restHeight)
        }
        panel.setFrameOrigin(origin)
    }

    func show(_ state: OverlayModel.State) {
        // A dictation over a meeting pill: a prompt that stands until
        // answered is parked and comes back when the cloud leaves; a toast
        // is let go. Either way the panel goes back into display shares.
        if model.state.isMeeting, !state.isMeeting {
            if model.state.isStanding { model.pendingMeeting = model.state }
            panel.sharingType = .readOnly
        }
        if state == .arming {
            model.level = 0
            model.shownAt = Date()
            model.departedAt = nil
            model.struckAt = nil
            model.backdrop = nil
        }
        // Lightning on the pin, and again as the dictation ends.
        if state == .pinned || (state == .transcribing && model.isRecording) { model.struckAt = Date() }
        model.closeNow = false
        model.state = state
        resample()
        model.copied = false
        if !panel.isVisible || panel.alphaValue == 0 || placedFor != model.presentation { reposition() }
        panel.orderFrontRegardless()
        updateClickThrough()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 1
        }
    }

    /// Shows a meeting state now, or parks it while the cloud is up so a
    /// dictation loses neither a prompt nor a toast; `hide` shows it when
    /// the cloud leaves. A meeting pill is kept out of display shares.
    func showMeeting(_ state: OverlayModel.State) {
        if model.presentation == .cloud {
            model.pendingMeeting = state
            return
        }
        model.pendingMeeting = nil
        panel.sharingType = .none
        show(state)
    }

    /// Takes a meeting state down, shown or parked. Nothing else is touched.
    func hideMeeting(_ state: OverlayModel.State) {
        if model.pendingMeeting == state { model.pendingMeeting = nil }
        if model.state == state { hide() }
    }

    func hide() {
        sampling?.cancel()
        sampling = nil
        if model.state.isMeeting { panel.sharingType = .readOnly }
        let closeNow = model.closeNow
        model.closeNow = false
        guard panel.isVisible else { model.state = .hidden; showPendingMeeting(); return }
        if closeNow {
            panel.alphaValue = 0
            panel.orderOut(nil)
            model.state = .hidden
            showPendingMeeting()
            return
        }
        // The cloud draws in a little as it fades. The pill just fades.
        let shrinking = model.presentation == .cloud
        if shrinking, model.departedAt == nil { model.departedAt = Date() }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = shrinking ? PuffView.departureDuration : 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                self.model.state = .hidden
                self.showPendingMeeting()
            }
        })
    }

    private func showPendingMeeting() {
        guard let pending = model.pendingMeeting else { return }
        showMeeting(pending)
    }

    func setLevel(_ level: Float) { model.level = level }

    private var sampling: Task<Void, Never>?

    /// Samples the screen under the cloud once as it arrives, and every
    /// second while pinned since the user may change windows under it. Not
    /// while it is leaving, and not without the setting and the grant.
    private func resample() {
        sampling?.cancel()
        sampling = nil
        let wanted = model.presentation == .cloud && (model.state == .arming || model.state == .recording || model.state == .pinned)
        guard wanted, Settings.shared.cloudMatchesBackdrop, CGPreflightScreenCaptureAccess() else { return }
        let repeating = model.state == .pinned
        sampling = Task { [weak self] in
            repeat {
                guard let self, !Task.isCancelled else { return }
                let rect = cloudRect
                let number = panel.windowNumber
                if let backdrop = await ScreenSampler.sample(rect: rect, excluding: number), !Task.isCancelled {
                    model.backdrop = backdrop
                    Settings.shared.lastBackdrop = backdrop
                }
                guard repeating else { return }
                try? await Task.sleep(for: .seconds(1))
            } while !Task.isCancelled
        }
    }

    /// The cloud's clickable circle, in screen coordinates.
    private var cloudRect: NSRect {
        let diameter = CloudView.size * 0.45
        let centre = NSPoint(x: panel.frame.midX, y: panel.frame.minY + CloudView.restHeight)
        return NSRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2, width: diameter, height: diameter)
    }
}

/// AppKit keeps a window's top edge under the menu bar whenever its frame is
/// set. The cloud at the top has to sit over the menu bar, and at a side it
/// hangs partly off the screen, so this panel takes the frame it is given.
private final class UnconstrainedPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct OverlayRoot: View {
    @Bindable var model: OverlayModel
    let onPillFrame: (CGRect) -> Void
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.clear
            switch model.presentation {
            case .cloud:
                CloudView(model: model)
                    .id(model.shownAt)
                    .transition(.opacity)
            case .pill:
                PillView(model: model)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { onPillFrame($0) }
                    .padding(.bottom, CloudView.restHeight - 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
            case .none:
                EmptyView()
            }
        }
        .frame(width: OverlayPanel.size.width, height: OverlayPanel.size.height, alignment: .bottom)
        .animation(.spring(duration: 0.46, bounce: 0.1), value: model.presentation)
    }
}
