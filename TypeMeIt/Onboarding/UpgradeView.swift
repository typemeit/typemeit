import SwiftUI

/// The panel a person sees when the speech model they installed is not the
/// current one. Dictation waits for the download, so the panel has no way to
/// put it off, and closes itself once the model is installed. The name, the
/// reason and the size come from `ModelStore`, so the next swap reuses it.
struct UpgradeView: View {
    var installed: () -> Void
    @State private var modelStore = ModelStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(ModelStore.upgradeTitle)
                    .font(DesignTokens.Fonts.display3)
                    .tracking(DesignTokens.Tracking.display3)
                    .foregroundStyle(DesignTokens.Colors.ink)
                Text(ModelStore.upgradeReason)
                    .font(DesignTokens.Fonts.body)
                    .foregroundStyle(DesignTokens.Colors.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SquareRows { ModelDownloadRows() }
                .padding(.top, 24)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 520, height: 240)
        .background(DesignTokens.Colors.paper)
        .tint(DesignTokens.Colors.ink)
        .onAppear { if modelStore.state == .installed { installed() } }
        .onChange(of: modelStore.state) { _, state in if state == .installed { installed() } }
    }
}

/// The speech model's row, whatever state its download is in: the download
/// button, the bar with its progress, a retry. Onboarding's model step and
/// the upgrade panel both show it.
struct ModelDownloadRows: View {
    @State private var modelStore = ModelStore.shared

    var body: some View {
        switch modelStore.state {
        case .installed:
            SquareSettingsRow(label: ModelStore.displayName) { SquareStatus("installed", done: true) }
        case .downloading(let received, let total):
            SquareSettingsRow(label: ModelStore.displayName) {
                Button("cancel") { modelStore.cancel() }.buttonStyle(SquareButtonStyle())
            }
            // Under the bar, not in the row's help popover: the
            // popover redrew on every progress tick and flickered.
            VStack(alignment: .leading, spacing: 8) {
                SquareBar(fraction: Double(received) / Double(max(total, 1)), width: nil, height: 6, track: DesignTokens.Colors.inkA08)
                    .animation(.easeOut(duration: DesignTokens.Duration.n2), value: received)
                Text(modelStore.reconnecting ? "reconnecting…" : "\(ModelStore.sizeLabel(received)) of \(ModelStore.sizeLabel(total))")
                    .font(DesignTokens.Fonts.micro.monospaced())
                    .foregroundStyle(DesignTokens.Colors.ink2)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { SquareRule() }
        case .verifying:
            SquareSettingsRow(label: ModelStore.displayName) { SquareStatus("checking the model…") }
        case .failed(let message):
            SquareSettingsRow(label: ModelStore.displayName, help: message.lowercased()) {
                Button("retry") { modelStore.download() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .missing:
            SquareSettingsRow(label: ModelStore.displayName, help: "\(ModelStore.sizeLabel(ModelStore.expectedBytes)), downloaded once") {
                Button("download") { modelStore.download() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        }
    }
}
