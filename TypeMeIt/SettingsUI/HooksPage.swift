import AppKit
import SwiftUI

/// The hooks tab: every prompt Claude Code can run on a finished
/// meeting, one line each with its switch, opening in place to edit. Hooks
/// run in Claude Code with the ai assistant's folder, model and permissions,
/// so the header says so and links there; without Claude Code the list is
/// shown but can't be switched.
struct HooksPage: View {
    @State private var settings = Settings.shared
    @State private var claudeCheck = ClaudeCheck.shared
    /// The hook open for editing; first the one a meeting asked for.
    @State private var editing: UUID? = AppState.shared.editHook
    @State private var deleting: UUID?
    /// A hook being written: kept out of the list until it has a name.
    @State private var draft: MeetingHook?

    private var ready: Bool { ClaudeRun.isAvailable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SquarePageHeader(title: "hooks", count: counted(settings.meetingHooks.count, "hook"), status: status,
                             linkTitle: "ai settings", onLink: showAssistant)
            HStack {
                Spacer()
                Button("new hook", action: add)
                    .buttonStyle(SquareButtonStyle(kind: .primary))
                    .disabled(!ready || draft != nil)
            }
            .padding(.horizontal, 20)
            .frame(height: 52)
            .overlay(alignment: .bottom) { SquareRule() }
            if !ready, !Sandbox.isActive {
                HStack(spacing: 12) {
                    Text("hooks run in claude code").font(Square.mono(12)).foregroundStyle(DesignTokens.Colors.ink2)
                    Spacer()
                    Button("install") { NSWorkspace.shared.open(ClaudeRun.installPage) }.buttonStyle(SquareButtonStyle(kind: .primary))
                }
                .padding(.horizontal, 20)
                .frame(height: 52)
                .overlay(alignment: .bottom) { SquareRule() }
            }
            if let draft = Binding($draft) { draftRow(draft) }
            if settings.meetingHooks.isEmpty, draft == nil {
                Text("no hooks yet")
                    .font(Square.mono(12))
                    .foregroundStyle(DesignTokens.Colors.ink3)
                    .padding(20)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach($settings.meetingHooks) { $hook in row($hook).id(hook.id) }
                        }
                    }
                    // A hook opened from a meeting is scrolled to.
                    .task { if let editing { reader.scrollTo(editing, anchor: .center) } }
                }
                .disabled(!ready)
                .opacity(ready ? 1 : 0.45)
            }
            Spacer(minLength: 0)
        }
        .toggleStyle(SquareSwitchStyle())
        .labelsHidden()
        .onAppear {
            AppState.shared.editHook = nil
            guard AppState.shared.startNewHook else { return }
            AppState.shared.startNewHook = false
            if ready { add() }
        }
    }

    private var status: String {
        guard ready else { return "needs claude code" }
        return "\(settings.meetingHooks.filter(\.on).count) on"
    }

    private func row(_ hook: Binding<MeetingHook>) -> some View {
        let id = hook.wrappedValue.id
        let open = editing == id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Toggle(hook.wrappedValue.name, isOn: hookSwitch(id))
                Button { editing = open ? nil : id } label: {
                    HStack(spacing: 16) {
                        Text(hook.wrappedValue.name)
                            .font(Square.mono(13))
                            .foregroundStyle(DesignTokens.Colors.ink)
                            .lineLimit(1)
                            .frame(width: 180, alignment: .leading)
                        Text(open ? "" : hook.wrappedValue.prompt.split(separator: "\n").first.map(String.init) ?? "")
                            .font(Square.sans(13))
                            .foregroundStyle(DesignTokens.Colors.ink2)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SquareIcon("akar-chevron-down", size: 10)
                            .foregroundStyle(DesignTokens.Colors.ink2)
                            .rotationEffect(.degrees(open ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "close \(hook.wrappedValue.name)" : "edit \(hook.wrappedValue.name)")
            }
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    SquareField(placeholder: "name", text: hook.name)
                    SquarePromptEditor(text: hook.prompt, placeholder: "what claude should do with the meeting")
                    HStack {
                        Spacer()
                        Button("delete") { deleting = id }
                            .buttonStyle(SquareButtonStyle(kind: .quiet, small: true))
                            .squareConfirmDelete(isPresented: Binding(get: { deleting == id }, set: { if !$0 { deleting = nil } }),
                                                 title: "delete \(hook.wrappedValue.name)?") { remove(id) }
                    }
                }
                .padding(.leading, 46)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { SquareRule() }
    }

    /// The new hook's fields, over the list; save adds it switched on.
    private func draftRow(_ hook: Binding<MeetingHook>) -> some View {
        let named = !hook.wrappedValue.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            SquareField(placeholder: "name", text: hook.name)
            SquarePromptEditor(text: hook.prompt, placeholder: "what claude should do with the meeting")
            HStack(spacing: 8) {
                Spacer()
                Button("cancel") { draft = nil }
                    .buttonStyle(SquareButtonStyle(kind: .quiet, small: true))
                    .keyboardShortcut(.cancelAction)
                Button("save") { save(hook.wrappedValue) }
                    .buttonStyle(SquareButtonStyle(kind: .primary, small: true))
                    .disabled(!named)
            }
        }
        .padding(.leading, 46)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { SquareRule() }
    }

    private func add() {
        editing = nil
        draft = MeetingHook(name: "")
    }

    private func save(_ hook: MeetingHook) {
        var saved = hook
        saved.name = hook.name.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.meetingHooks.append(saved)
        draft = nil
        hookSwitch(saved.id).wrappedValue = true
    }

    private func remove(_ id: UUID) {
        settings.meetingHooks.removeAll { $0.id == id }
        if editing == id { editing = nil }
    }

    /// A hook's switch, by id: going on checks Claude Code and goes back off
    /// if the check fails, which can end after the list has changed.
    private func hookSwitch(_ id: UUID) -> Binding<Bool> {
        Binding(get: { settings.meetingHooks.first { $0.id == id }?.on ?? false }, set: { on in
            setOn(id, on)
            if on { claudeCheck.ensure { passed in if !passed { setOn(id, false) } } }
        })
    }

    private func setOn(_ id: UUID, _ on: Bool) {
        guard let index = settings.meetingHooks.firstIndex(where: { $0.id == id }) else { return }
        settings.meetingHooks[index].on = on
    }

    private func showAssistant() {
        AppState.shared.revealSection = .assistant
        AppState.shared.settingsTab = .settings
    }
}
