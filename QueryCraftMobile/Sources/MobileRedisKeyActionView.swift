import SwiftUI
import QueryCraftMobileCore

struct MobileRedisKeyActionView: View {
    @Bindable var action: MobileRedisKeyAction
    let close: () -> Void
    @State private var confirmDiscard = false
    @State private var confirmMetadataReload = false
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section("DB \(action.database) · \(action.type == .unknown ? "Redis" : action.type.rawValue)") {
                        if case .rename(let reference) = action.mode { LabeledContent("原名称", value: reference.name) }
                        if action.isMetadata { Text(action.name).lineLimit(3).truncationMode(.middle).textSelection(.enabled) }
                        else {
                            LabeledContent(action.isCreation ? "键名" : "新名称") {
                                TextField("请输入", text: $action.name).multilineTextAlignment(.trailing)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("redisKeyName")
                            }
                        }
                        Toggle("安全锁", isOn: Binding(get: { action.safetyLock.isEnabled }, set: { if $0 { action.safetyLock.enable() } else { action.safetyLock.disable() } }))
                    }.disabled(!action.canEdit)
                    if action.isCreation {
                        if action.type == .string {
                            Section("字符串") {
                                MobileSegmentedTextEditor(text: $action.text, accessibilityIdentifier: "redisNewString")
                            }.disabled(!action.canEdit)
                        } else {
                            Section("成员") {
                                ForEach(action.rows) { row in
                                    let input = $action.rows.identifiedRow(row)
                                    MobileRedisMemberRow(row: input, type: action.type,
                                        creationIndex: action.rows.firstIndex { $0.id == row.id },
                                        remove: { action.removeRow(row.id) })
                                }
                                Button("添加成员", action: action.addRow).disabled(action.rows.count >= 1_000)
                            }.disabled(!action.canEdit)
                        }
                    }
                    if action.isCreation || action.isExpiration {
                        Section("过期时间") {
                            Picker("到期方式", selection: $action.expirationMode) {
                                ForEach(RedisKeyExpirationMode.allCases) { Text($0.title).tag($0) }
                            }
                            LabeledContent("TTL（毫秒）") {
                                TextField("正整数", text: $action.ttl).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                                    .accessibilityIdentifier("redisKeyTTL").disabled(action.expirationMode == .persistent)
                            }
                        }.disabled(!action.canEdit)
                    }
                    Section {
                        Text(action.isMetadata ? (action.isDeletion ? "将删除此键及所有成员。此操作不可撤销。" : "修改当前键的过期时间，保留内容。以执行时刻开始计算新 TTL。") : action.isCreation ? "仅当键不存在时创建；同名键会中止提交。" : "保留原键的数据与 TTL；同名目标存在时不会覆盖。")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("预览命令", action: action.prepare).disabled(!action.canEdit || action.safetyLock.isEnabled)
                    }
                    if let preview = action.preview {
                        Section("确认命令 · DB \(action.database)") {
                            Text(String(preview.prefix(65_536)) + (preview.count > 65_536 ? "\n…（预览显示前缀；提交完整命令）" : "")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("确认提交", role: action.isDeletion ? .destructive : nil) { action.submit() }.disabled(!action.canEdit || action.safetyLock.isEnabled).id("redisKeyConfirmation")
                        }
                    }
                    if let statuses = action.statuses {
                        Section("当前状态") {
                            ForEach(statuses, id: \.reference.id) { status in
                                VStack(alignment: .leading) {
                                    Text(status.reference.name).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                                    Text(status.exists ? "\(status.reference.type.rawValue) · \(status.ttl == -1 ? "永久" : "TTL \(status.ttl) ms")" : "键不存在")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.id("redisKeyStatus")
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: action.preview) { _, value in if value != nil { proxy.scrollTo("redisKeyConfirmation", anchor: .bottom) } }
                .onChange(of: action.statuses != nil) { _, value in if value { proxy.scrollTo("redisKeyStatus", anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).opacity(action.isLoading || action.isSubmitting ? 1 : 0)
                    Text(action.message ?? (action.isSubmitting ? "正在提交…" : action.isLoading ? "正在读取键属性…" : "修改后先预览，再确认提交。"))
                        .font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    if action.needsVerification || action.isMetadata && action.submitted == nil && action.message != nil {
                        Button(action.needsVerification ? "读取核实" : "重试读取") {
                            if action.needsVerification { action.verify() }
                            else if action.metadata != nil && action.hasDraft { confirmMetadataReload = true }
                            else { action.loadMetadata() }
                        }.disabled(action.isLoading || action.isSubmitting || action.isBackgrounded)
                    }
                }.padding(.horizontal, 16).frame(height: 76).background(.bar)
            }
            .navigationTitle(action.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("完成") { if action.submitted == nil && action.hasDraft { confirmDiscard = true } else { close() } }.disabled(!action.canClose)
            } }
            .confirmationDialog("重新读取会丢弃当前 TTL 草稿。", isPresented: $confirmMetadataReload, titleVisibility: .visible) {
                Button("丢弃草稿并读取", role: .destructive) { action.loadMetadata() }
            }
            .confirmationDialog("放弃尚未提交的草稿？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃草稿并关闭", role: .destructive, action: close)
            }
        }.interactiveDismissDisabled()
    }
}
