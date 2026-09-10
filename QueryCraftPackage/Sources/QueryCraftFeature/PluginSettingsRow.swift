import SwiftUI

struct PluginSettingsRow: View {
    let item: DatabaseDriverCatalogItem
    let install: @MainActor @Sendable () -> Void
    let update: @MainActor @Sendable () -> Void
    let uninstall: @MainActor @Sendable () -> Void

    private var copy: SettingsCopy {
        SettingsCopy(language: .activeInterfaceLanguage)
    }

    var body: some View {
        HStack(spacing: 12) {
            DatabaseBrandIcon(databaseType: item.entry.databaseType)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.entry.displayName)
                        .font(.headline)
                    if let installedVersion = item.installedVersion {
                        Text(copy.installedPluginVersion(installedVersion))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                statusView
            }

            Spacer(minLength: 12)
            actionControls
        }
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.installationState {
        case .installing(let progress), .updating(let progress):
            if progress.phase == .downloading {
                HStack(spacing: 8) {
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction)
                            .frame(
                                minWidth: 96,
                                idealWidth: 140,
                                maxWidth: 160
                            )
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    if let detail = progress.downloadDetail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(progress.phase.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        case .updateAvailable:
            Text(updateDescription)
                .foregroundStyle(.orange)
                .font(.subheadline)
        case .updateReady:
            Text(copy.pluginUpdateReady)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        case .installed:
            Text(copy.pluginUpToDate)
                .foregroundStyle(.secondary)
                .font(.subheadline)
        case .notInstalled:
            Text(notInstalledDescription)
                .foregroundStyle(.secondary)
                .font(.subheadline)
                .help(item.availabilityErrorMessage ?? "")
        case .uninstalling:
            Text(AppCopy.current.text("正在卸载...", "Uninstalling..."))
                .foregroundStyle(.secondary)
                .font(.subheadline)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.subheadline)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        HStack(spacing: 7) {
            switch item.installationState {
            case .notInstalled, .failed:
                Button(
                    item.installationState == .notInstalled
                        ? copy.installPlugin
                        : copy.retryPluginOperation,
                    action: install
                )
                .disabled(item.availableVersion == nil || item.availabilityErrorMessage != nil)
            case .updateAvailable:
                Button(copy.updatePlugin, action: update)
                    .buttonStyle(.borderedProminent)
            case .installing, .updating, .uninstalling:
                ProgressView()
                    .controlSize(.small)
            case .installed, .updateReady:
                EmptyView()
            }

            if item.installationState.hasInstalledDriver {
                WorkspaceInlineIconButton(
                    systemImageName: "trash",
                    title: copy.uninstallPlugin,
                    isEnabled: !item.installationState.isBusy,
                    action: uninstall
                )
            }
        }
    }

    private var notInstalledDescription: String {
        guard item.availabilityErrorMessage == nil,
              let version = item.availableVersion
        else {
            return copy.pluginUnavailable
        }
        return joinedDescription(
            copy.availablePluginVersion(version),
            formattedDownloadSize
        )
    }

    private var updateDescription: String {
        guard let installedVersion = item.installedVersion,
              let availableVersion = item.availableVersion
        else {
            return copy.pluginUpdateAvailable
        }
        return joinedDescription(
            copy.pluginVersionUpdate(
                from: installedVersion,
                to: availableVersion
            ),
            formattedDownloadSize
        )
    }

    private var formattedDownloadSize: String? {
        item.downloadSize?.formatted(.byteCount(style: .file))
    }

    private func joinedDescription(
        _ leading: String,
        _ trailing: String?
    ) -> String {
        guard let trailing else { return leading }
        return "\(leading) · \(trailing)"
    }
}
