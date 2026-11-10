import SwiftUI

struct CloudSyncSettingsPane: View {
    let controller: CloudSyncController
    @State private var isChanging = false

    private var copy: CloudSyncCopy { .current }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { controller.isEnabled },
                    set: { enabled in
                        isChanging = true
                        Task {
                            await controller.setEnabled(enabled)
                            isChanging = false
                        }
                    }
                )) {
                    SettingsControlLabel(title: copy.toggle, description: copy.summary)
                }
                .disabled(!controller.isAvailableInBuild || isChanging)

                LabeledContent {
                    Button(copy.syncNow) { Task { await controller.syncNow() } }
                        .disabled(!controller.isEnabled || controller.status == .syncing)
                } label: {
                    statusLabel
                }
            } footer: {
                Text(copy.localDataKept)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch controller.status {
        case .off:
            Label(controller.isEnabled ? copy.waiting : copy.off, systemImage: "icloud.slash")
                .foregroundStyle(.secondary)
        case let .unavailable(message):
            Label(message, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.secondary)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(copy.syncing)
            }
        case let .synced(date):
            Label(copy.lastSynced(date), systemImage: "checkmark.icloud")
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.icloud")
                .foregroundStyle(.orange)
        }
    }
}
