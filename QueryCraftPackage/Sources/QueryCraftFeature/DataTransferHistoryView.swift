import SwiftUI

struct DataTransferHistoryView: View {
    @Bindable var manager: DataTransferManager
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppCopy.current.text("后台传输与历史", "Background transfers and history")).font(.headline)
                Spacer()
                Button(AppCopy.current.text("清除已结束任务", "Clear finished tasks"), action: manager.clearFinished)
            }.padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(manager.runs) { run in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(run.name).font(.headline)
                                    Spacer()
                                    Text(run.status.title).foregroundStyle(color(run.status))
                                    if run.status.isActive {
                                        Button(AppCopy.current.text("取消传输", "Cancel transfer")) { manager.cancel(run.id) }.disabled(run.status == .cancelling)
                                    }
                                }
                                Text(run.sourceLabel + " → " + run.targetLabel).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                if run.status.isActive {
                                    TimelineView(.periodic(from: run.createdAt, by: 1)) { context in
                                        Text(AppCopy.current.text("已用 \(Int(context.date.timeIntervalSince(run.createdAt))) 秒 · 已提交 \(run.committedRows) 行", "\(Int(context.date.timeIntervalSince(run.createdAt))) seconds · \(run.committedRows) rows committed")).font(.caption).monospacedDigit()
                                    }
                                } else {
                                    Text(AppCopy.current.text("已提交 \(run.committedRows) 行", "\(run.committedRows) rows committed")).font(.caption).monospacedDigit()
                                }
                                let completed = run.items.filter { !$0.status.isActive }.count
                                ProgressView(value: Double(completed), total: Double(max(1, run.items.count)))
                                ForEach(run.items) { item in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(item.name).font(.callout).lineLimit(1)
                                            Spacer()
                                            Text("\(item.readRows) / \(item.committedRows)").font(.caption.monospacedDigit())
                                                .help(AppCopy.current.text("读取行数 / 已提交行数", "Rows read / rows committed"))
                                            Text(item.status.title).font(.caption).foregroundStyle(color(item.status))
                                        }
                                        if !item.message.isEmpty { Text(item.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                                    }
                                }
                                if !run.message.isEmpty { Text(run.message).font(.caption).textSelection(.enabled) }
                                if !run.backupTables.isEmpty {
                                    Text(AppCopy.current.text("保留的原表备份：", "Retained original-table backups: ") + run.backupTables.joined(separator: ", "))
                                        .font(.caption.monospaced()).foregroundStyle(.orange).textSelection(.enabled)
                                }
                            }.padding(8)
                        }
                    }
                    if manager.runs.isEmpty { Text(AppCopy.current.text("尚无传输任务", "No transfer tasks yet")).foregroundStyle(.secondary).padding() }
                }.padding(16)
            }
            if !manager.persistenceError.isEmpty { Text(manager.persistenceError).font(.caption).foregroundStyle(.red).textSelection(.enabled).padding(10) }
        }
    }
    private func color(_ status: TransferRunStatus) -> Color {
        switch status {
        case .completed: .green
        case .failed, .uncertain: .red
        case .partial, .interrupted, .cancelled: .orange
        default: .secondary
        }
    }
}
