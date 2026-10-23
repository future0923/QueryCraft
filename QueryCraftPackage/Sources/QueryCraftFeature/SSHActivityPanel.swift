import SwiftUI

struct SSHActivityPanel: View {
    @State private var model: SSHActivityModel
    @State private var confirmation: SSHActivityConfirmation?
    @Environment(\.dismiss) private var dismiss
    init(profile: SSHConnection, directory: URL) {
        _model = State(initialValue: SSHActivityModel(profile: profile, service: SSHActivityService(directory: directory, profile: profile)))
    }
    init(model: SSHActivityModel) { _model = State(initialValue: model) }
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    private var detailKey: String { "\(String(describing: model.selection))-\(model.stream)-\(model.refreshID)-\(String(describing: confirmation?.id))" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(copy("任务与传输", "Tasks and transfers")).font(.headline)
                    Text("\(model.profile.name) · \(model.profile.username)@\(model.profile.host):\(model.profile.port)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Toggle(copy("自动更新", "Auto update"), isOn: $model.autoRefresh).toggleStyle(.checkbox)
                Button { model.refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .help(copy("刷新列表和当前详情", "Refresh list and current details"))
                    .disabled(model.actionLoading)
            }.padding(16)
            Divider()
            HSplitView {
                activityList.frame(minWidth: 230, idealWidth: 260, maxWidth: 310)
                SSHActivityDetail(model: model, confirm: confirm).frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).frame(width: 16).opacity(model.listLoading || model.detailLoading || model.actionLoading ? 1 : 0)
                Text(model.listError ?? model.feedback).font(.caption).lineLimit(2)
                    .foregroundStyle(model.listError == nil ? Color.secondary : .red)
                Spacer(minLength: 4)
                Button(copy("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 16).frame(height: 58)
        }
        .frame(minWidth: 780, idealWidth: 920, minHeight: 600, idealHeight: 650)
        .task(id: model.refreshID) {
            await model.refreshList()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if model.autoRefresh && confirmation == nil { await model.refreshList() }
            }
        }
        .task(id: detailKey) {
            guard confirmation == nil else { return }
            await model.refreshDetail()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                if model.autoRefresh && confirmation == nil && (model.selection?.isTask == true || model.detail == nil) { await model.refreshDetail() }
            }
        }
        .sheet(item: $confirmation) { item in SSHActivityConfirmationSheet(model: model, confirmation: item) }
        .onDisappear { let service = model.service; Task { await service.close() } }
    }
    private func confirm(_ action: SSHActivityAction) {
        guard let selection = model.selection else { return }
        confirmation = SSHActivityConfirmation(action: action, selection: selection, inspectionToken: model.inspectionToken, transfer: model.currentTransfer?.record)
    }
    private var activityList: some View {
        List(selection: Binding(get: { model.selection }, set: { model.select($0) })) {
            Section(copy("后台任务", "Background tasks")) {
                ForEach(model.snapshot?.tasks ?? []) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(String(record.id.uuidString.prefix(8)), systemImage: "terminal")
                            .font(.system(.body, design: .monospaced))
                        Text(record.createdAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(SSHActivitySelection.task(record.id))
                }
                if model.snapshot?.tasks.isEmpty == true { Text(copy("暂无登记的任务", "No tracked tasks")).font(.caption).foregroundStyle(.secondary) }
            }
            Section(copy("进行中与待核对传输", "Active and unresolved transfers")) {
                ForEach(model.snapshot?.transfers ?? []) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(URL(fileURLWithPath: item.record.remotePath).lastPathComponent,
                            systemImage: item.record.upload ? "arrow.up.doc" : "arrow.down.doc").lineLimit(1)
                        Text(item.active ? (item.cancellationRequested ? copy("已请求取消", "Cancellation requested") : copy("传输中", "Transferring")) : copy("需要核对结果", "Outcome requires inspection"))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 3).tag(SSHActivitySelection.transfer(item.id))
                }
                if model.snapshot?.transfers.isEmpty == true { Text(copy("暂无进行中或待核对的传输", "No active or unresolved transfers")).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .listStyle(.sidebar).disabled(model.actionLoading)
    }
}

private struct SSHActivityDetail: View {
    @Bindable var model: SSHActivityModel
    let confirm: (SSHActivityAction) -> Void
    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let snapshot = model.snapshot, !snapshot.policyEnabled || !snapshot.pluginAvailable {
                Text(!snapshot.pluginAvailable ? copy("请先安装 SSH 插件，再重新打开面板。", "Install SSH, then reopen this panel.") : copy("MCP 当前未启用。远程操作沿用 MCP 的工具开关、账号授权和全局上限。", "MCP is disabled. Remote actions use its tool switches, account grants and global limit."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let selection = model.selection {
                Text(selection.id.uuidString).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                if selection.isTask { taskDetail } else { transferDetail }
            } else {
                Spacer()
                Text(copy("选择任务或传输查看详情", "Select a task or transfer")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            Text(model.detailError ?? "").font(.caption).foregroundStyle(.red).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }.padding(16)
    }
    private var taskDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(SSHActivityCopy.state(model.taskState)).font(.headline)
                Spacer()
                if let code = model.detail?.objectValue?["exit_code"]?.intValue { Text(copy("退出码 \(code)", "Exit code \(code)")).font(.caption) }
            }
            HStack {
                Picker(copy("日志", "Logs"), selection: Binding(get: { model.stream }, set: { model.changeStream($0) })) {
                    Text(copy("标准输出", "stdout")).tag("stdout")
                    Text(copy("标准错误", "stderr")).tag("stderr")
                }.pickerStyle(.segmented).frame(maxWidth: 300)
                Spacer(minLength: 0)
            }
            Text(copy("字节窗口 \(model.logWindowStart)–\(model.nextOffset)", "Byte window \(model.logWindowStart)–\(model.nextOffset)")
                 + (model.logFinal ? copy(" · 已到结尾", " · final") : ""))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            GeometryReader { geometry in
                ScrollView([.vertical, .horizontal]) {
                    Text(model.log.isEmpty ? " " : model.log).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(minWidth: max(0, geometry.size.width - 20), minHeight: max(0, geometry.size.height - 20), alignment: .topLeading).padding(10)
                }
            }.background(.background).clipShape(RoundedRectangle(cornerRadius: 6)).frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.detail?.objectValue?["truncated"] == true || model.detail?.objectValue?["output_incomplete"] == true {
                Text(copy("远端日志已截断或未完整排空；显示内容可能不完整。", "Remote logs were truncated or incompletely drained; output may be incomplete."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button(copy("读取更多", "Read more")) { model.refreshID = UUID() }.disabled(model.detailLoading || model.actionLoading || !model.allows("ssh_task_output"))
                Spacer(minLength: 0)
                if model.terminalTask {
                    Button(copy("清理任务", "Clean up task"), role: .destructive) { confirm(.removeTask) }.disabled(!model.allows("ssh_remove_task"))
                } else {
                    Button(copy("忘记记录…", "Forget record…")) { confirm(.forgetTask) }.disabled(!model.allows("ssh_forget_task"))
                    Button(copy("取消任务…", "Cancel task…"), role: .destructive) { confirm(.cancelTask) }
                        .disabled(!["running", "starting"].contains(model.taskState) || !model.allows("ssh_cancel_task"))
                }
            }.disabled(model.actionLoading || model.detailLoading)
        }
    }
    private var transferDetail: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let transfer = model.currentTransfer {
                Text(transfer.active ? (transfer.cancellationRequested ? copy("已请求取消，等待传输结束", "Cancellation requested; waiting for transfer") : copy("正在传输", "Transferring")) : copy("传输结果待核对", "Transfer outcome requires inspection")).font(.headline)
                path(copy("远程路径", "Remote path"), transfer.record.remotePath)
                path(copy("本机路径", "Local path"), transfer.record.localPath)
                path(copy("临时路径", "Staging path"), transfer.record.stagingPath)
                if let metadata = model.detail?.objectValue?["metadata"]?.objectValue {
                    Text(copy("临时文件", "Staging") + ": " + metadataDescription(metadata["staging"]) + "\n" + copy("目标文件", "Destination") + ": " + metadataDescription(metadata["destination"]))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(transfer.active ? copy("传输进行中不显示估算百分比。取消请求不会证明目标文件未写入，结束后仍需核对结果。", "No estimated percentage is shown. Cancellation does not prove the destination was untouched; inspect the outcome afterward.") : copy("清理仅删除这条记录的临时文件，不修改目标文件，也不自动重传。元数据不能证明目标内容完整。", "Cleanup removes only this record's staging file, preserves the destination and never retries. Metadata does not verify destination content."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack {
                    Spacer()
                    if transfer.active {
                        Button(copy("取消传输…", "Cancel transfer…"), role: .destructive) { confirm(.cancelTransfer) }
                            .disabled(transfer.record.cancellationVersion != 1 || transfer.cancellationRequested || !model.allows(transfer.record.upload ? "ssh_upload_file" : "ssh_download_file"))
                    } else {
                        Button(copy("清理临时文件…", "Clean up staging…"), role: .destructive) { confirm(.cleanupTransfer) }
                            .disabled(model.inspectionToken == nil || !model.allows("ssh_cleanup_transfer"))
                    }
                }.disabled(model.actionLoading || model.detailLoading)
                if transfer.active && transfer.record.cancellationVersion != 1 {
                    Text(copy("该传输由旧版 MCP 运行时持有，不能从面板取消。", "This transfer is owned by an older MCP runtime and cannot be cancelled here."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else { Spacer() }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func path(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
        }
    }
    private func metadataDescription(_ value: MCPJSONValue?) -> String {
        guard let object = value?.objectValue else { return "—" }
        guard object["exists"] == true else { return copy("不存在", "Absent") }
        return (object["type"]?.stringValue ?? "—") + " · " + String(object["size_bytes"]?.intValue ?? 0) + " B"
    }
}

enum SSHActivityCopy {
    static func state(_ value: String) -> String {
        let zh = switch value {
        case "starting": "正在启动"
        case "running": "运行中"
        case "completed": "已完成"
        case "cancelled": "已取消"
        case "timed_out": "已超时"
        case "failed": "执行失败"
        case "unknown": "状态未知，请人工核实"
        default: "尚未查询状态"
        }
        return AppCopy.current.text(zh, value == "not_polled" ? "Status not queried" : value)
    }
}
