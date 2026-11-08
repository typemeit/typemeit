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
            ModelDownloadRows()
                .padding(.top, 24)
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(width: 520, height: 420)
        .background(DesignTokens.Colors.paper)
        .tint(DesignTokens.Colors.ink)
        .onAppear { if modelStore.state == .installed { installed() } }
        .onChange(of: modelStore.state) { _, state in if state == .installed { installed() } }
    }
}

/// The speech model's row, whatever state its download is in: the download
/// button, the puff filling in as it downloads, a retry. Onboarding's model step and
/// the upgrade panel both show it.
struct ModelDownloadRows: View {
    @State private var modelStore = ModelStore.shared

    var body: some View {
        VStack(spacing: 0) {
            SquareRows { row }
            // Under the row, not in its help popover: the popover redrew on
            // every progress tick and flickered.
            if case .downloading(let received, let total) = modelStore.state {
                VStack(spacing: 12) {
                    SquarePuffProgress(fraction: Double(received) / Double(max(total, 1)))
                    Text(modelStore.reconnecting ? "reconnecting…" : "\(ModelStore.sizeLabel(received)) of \(ModelStore.sizeLabel(total))")
                        .font(DesignTokens.Fonts.body.monospaced())
                        .foregroundStyle(DesignTokens.Colors.ink2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            }
        }
    }

    @ViewBuilder private var row: some View {
        switch modelStore.state {
        case .installed:
            SquareSettingsRow(label: ModelStore.displayName, caption: "parakeet") { SquareStatus("installed", done: true) }
        case .downloading:
            SquareSettingsRow(label: ModelStore.displayName) {
                Button("cancel") { modelStore.cancel() }.buttonStyle(SquareButtonStyle())
            }
        case .verifying:
            SquareSettingsRow(label: ModelStore.displayName) { SquareStatus("checking the model…") }
        case .failed(let message):
            SquareSettingsRow(label: ModelStore.displayName, help: message.lowercased()) {
                Button("retry") { modelStore.download() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        case .missing:
            SquareSettingsRow(label: ModelStore.displayName, caption: "parakeet · \(ModelStore.sizeLabel(ModelStore.expectedBytes))") {
                Button("download") { modelStore.download() }.buttonStyle(SquareButtonStyle(kind: .primary))
            }
        }
    }
}
