import SwiftUI

struct DatabaseDriverInstallationStatusView: View {
    let state: DatabaseDriverInstallationState

    var body: some View {
        Group {
            switch state {
            case .notInstalled:
                Text(AppCopy.current.text("未安装", "Not Installed"))
                    .foregroundStyle(.secondary)
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityLabel(
                        AppCopy.current.text("已安装", "Installed")
                    )
            case .updateAvailable:
                Text(AppCopy.current.text("有更新", "Update Available"))
                    .foregroundStyle(.orange)
            case .updateReady:
                Text(AppCopy.current.text("重启后更新", "Updates After Restart"))
                    .foregroundStyle(.secondary)
            case .uninstalling:
                VStack(alignment: .trailing, spacing: 4) {
                    Text(AppCopy.current.text("正在卸载...", "Uninstalling..."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ProgressView()
                        .controlSize(.small)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .accessibilityLabel(
                        AppCopy.current.text("安装失败", "Installation Failed")
                    )
            case .installing(let progress):
                progressView(progress)
            case .updating(let progress):
                progressView(progress)
            }
        }
        .frame(width: 220, alignment: .trailing)
    }

    private func progressView(
        _ progress: DatabaseDriverInstallationProgress
    ) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            if progress.phase != .downloading {
                Text(progress.phase.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
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
    }
}
