import SwiftUI

struct WorkspaceDataExportCenterView: View {
    @Bindable var manager: WorkspaceDataExportJobManager
    @State private var preferences = ApplicationPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if manager.jobs.isEmpty {
                ContentUnavailableView(
                    AppCopy.current.text("没有导出任务", "No Exports"),
                    systemImage: "arrow.down.doc",
                    description: Text(
                        AppCopy.current.text(
                            "导出进度和结果会显示在这里。",
                            "Export progress and results will appear here."
                        )
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(manager.jobs) { job in
                            WorkspaceDataExportJobRow(
                                job: job,
                                manager: manager
                            )
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)

                            if job.id != manager.jobs.last?.id {
                                Divider()
                                    .padding(.leading, 58)
                            }
                        }
                    }
                }
                .scrollContentBackground(.visible)
            }
        }
        .frame(minWidth: 540, minHeight: 220)
        .background(.background)
        .environment(\.locale, preferences.interfaceLocale)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(AppCopy.current.text("导出中心", "Export Center"))
                    .font(.headline)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(
                AppCopy.current.text("清除已完成", "Clear Finished"),
                systemImage: "trash",
                action: manager.clearFinishedJobs
            )
            .labelStyle(.iconOnly)
            .help(AppCopy.current.text("清除已完成", "Clear Finished"))
            .disabled(!manager.jobs.contains(where: { !$0.isActive }))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var summary: String {
        let activeCount = manager.activeJobCount
        guard activeCount > 0 else {
            return AppCopy.current.text(
                "当前没有进行中的任务",
                "No active exports"
            )
        }
        return AppCopy.current.text(
            "\(activeCount) 个任务正在处理",
            "\(activeCount) active exports"
        )
    }
}

private struct WorkspaceDataExportJobRow: View {
    @Bindable var job: WorkspaceDataExportJob
    let manager: WorkspaceDataExportJobManager

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: statusImage)
                .font(.title2)
                .foregroundStyle(statusColor)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(job.destination.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(job.format.rawValue.uppercased())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if job.isActive {
                    progress
                }

                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(statusTextColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 16)
            actions
        }
        .help(job.destination.path)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var progress: some View {
        if let total = job.estimatedRowCount, total > 0 {
            ProgressView(
                value: Double(min(job.completedRowCount, total)),
                total: Double(total)
            )
        } else if job.status == .queued {
            ProgressView(value: 0, total: 1)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if job.canCancel {
            Button(
                AppCopy.current.text("取消导出", "Cancel Export"),
                systemImage: "xmark",
                action: { manager.cancel(job) }
            )
            .labelStyle(.iconOnly)
            .help(AppCopy.current.text("取消导出", "Cancel Export"))
        } else if case .completed = job.status {
            Button(
                AppCopy.current.text("打开", "Open"),
                systemImage: "arrow.up.forward.app",
                action: { manager.open(job) }
            )
            .labelStyle(.iconOnly)
            .help(AppCopy.current.text("打开", "Open"))

            Button(
                AppCopy.current.text("在 Finder 中显示", "Show in Finder"),
                systemImage: "folder",
                action: { manager.reveal(job) }
            )
            .labelStyle(.iconOnly)
            .help(AppCopy.current.text("在 Finder 中显示", "Show in Finder"))
        }
    }

    private var statusImage: String {
        switch job.status {
        case .queued: "clock"
        case .exporting, .finalizing: "arrow.down.circle"
        case .completed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var statusTextColor: Color {
        if case .failed = job.status {
            return .red
        }
        return .secondary
    }

    private var statusText: String {
        switch job.status {
        case .queued:
            AppCopy.current.text("等待中", "Waiting")
        case .exporting:
            if let total = job.estimatedRowCount {
                AppCopy.current.text(
                    "已处理 \(job.completedRowCount) / \(total) 行",
                    "Processed \(job.completedRowCount) of \(total) rows"
                )
            } else {
                AppCopy.current.text(
                    "已处理 \(job.completedRowCount) 行",
                    "\(job.completedRowCount) rows processed"
                )
            }
        case .finalizing:
            AppCopy.current.text("正在完成文件…", "Finalizing file...")
        case .completed:
            AppCopy.current.text(
                "已完成 · \(job.completedRowCount) 行",
                "Completed · \(job.completedRowCount) rows"
            )
        case .cancelled:
            AppCopy.current.text("已取消", "Cancelled")
        case let .failed(message):
            message
        }
    }
}
