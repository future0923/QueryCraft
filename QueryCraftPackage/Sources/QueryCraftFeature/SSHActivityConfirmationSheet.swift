import SwiftUI

struct SSHActivityConfirmationSheet: View {
    @Bindable var model: SSHActivityModel
    let confirmation: SSHActivityConfirmation
    @State private var acknowledged = false
    @State private var operation: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    private var requiresAcknowledgment: Bool { [.cleanupTransfer, .forgetTask].contains(confirmation.action) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Text("\(model.profile.name) · \(model.profile.username)@\(model.profile.host):\(model.profile.port)")
                .font(.caption).foregroundStyle(.secondary)
            Text(confirmation.selection.id.uuidString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            if let record = confirmation.transfer {
                Text(copy("临时文件：", "Staging: ") + record.stagingPath + "\n" + copy("保留的目标：", "Preserved destination: ") + (record.upload ? record.remotePath : record.localPath))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(8)
            }
            if requiresAcknowledgment {
                Toggle(confirmation.action == .forgetTask ? copy("我知道远程任务可能仍在运行", "I understand the remote task may still be running") : copy("我已核对路径，且知道目标结果仍需另行验证", "I reviewed the paths and understand the destination outcome still needs verification"), isOn: $acknowledged)
                    .toggleStyle(.checkbox).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.detailError ?? "").font(.caption).foregroundStyle(.red).lineLimit(4).frame(minHeight: 36)
            HStack {
                ProgressView().controlSize(.small).opacity(model.actionLoading ? 1 : 0)
                Spacer()
                Button(copy("返回", "Back")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.actionLoading)
                Button(title, role: .destructive) {
                    operation = Task {
                        if await model.perform(confirmation, acknowledged: acknowledged) {
                            model.refreshID = UUID(); dismiss()
                        }
                    }
                }.disabled(model.actionLoading || model.detailLoading || (requiresAcknowledgment && !acknowledged) || model.selection != confirmation.selection)
            }
        }.padding(24).frame(width: 540)
        .interactiveDismissDisabled(model.actionLoading)
        .onDisappear { operation?.cancel() }
    }
    private var title: String {
        switch confirmation.action {
        case .cancelTask: copy("取消远程任务", "Cancel remote task")
        case .removeTask: copy("清理已结束任务", "Clean up finished task")
        case .forgetTask: copy("忘记本机记录", "Forget local record")
        case .cancelTransfer: copy("请求取消传输", "Request transfer cancellation")
        case .cleanupTransfer: copy("清理临时文件", "Clean up staging")
        }
    }
    private var explanation: String {
        switch confirmation.action {
        case .cancelTask: copy("将请求终止该任务监督器管理的进程组。已产生的远程修改不会撤销；提交后请查询实际状态。", "Request termination of the process group managed by this task's supervisor. Remote changes are not undone; query the actual state afterward.")
        case .removeTask: copy("仅在服务器确认任务已结束时，删除该任务的远程日志与本机登记。", "Remove this task's remote logs and local record only after the server confirms it has finished.")
        case .forgetTask: copy("只移除本机登记，不会停止远程任务，也不会删除远程日志。忘记后该任务不再出现在此列表。", "Remove only the local record. This does not stop the remote task or delete remote logs. The task will disappear from this list.")
        case .cancelTransfer: copy("向持有该传输的本机 MCP 进程请求取消。传输可能已经发布目标文件；取消不代表回滚，结束后仍须核对。", "Ask the local MCP process owning this transfer to cancel. The destination may already be published; cancellation is not rollback. Inspect the outcome afterward.")
        case .cleanupTransfer: copy("使用本次核对的元数据令牌，仅删除已登记的临时文件并移除记录。目标文件保持原样；变化的文件、符号链接或目录会被拒绝。", "Use the inspected metadata token to remove only the tracked staging file and its record. Preserve the destination; changed metadata, symlinks and directories are refused.")
        }
    }
}
