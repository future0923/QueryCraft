import SwiftUI

struct WorkspaceKafkaProducerSheet: View {
    let workspace: WorkspaceModel
    @Bindable var editor: WorkspaceKafkaProducerModel
    let close: () -> Void
    @State private var showsHeaders = false
    @State private var operation: Task<Void, Never>?
    @State private var showsUnlock = false
    private var copy: AppCopy { .current }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(copy.text("发送消息", "Send Message")).font(.headline)
                Spacer()
                Text(editor.topic).font(.system(.body, design: .monospaced)).textSelection(.enabled)
            }.padding(16)
            Divider()
            Form {
                TextField(copy.text("分区", "Partition"), text: $editor.partition,
                          prompt: Text(copy.text("自动分配", "Automatic")))
                    .accessibilityIdentifier("kafkaProducePartition")
                LabeledContent("Key") {
                    HStack {
                        TextField("Key", text: $editor.key).labelsHidden()
                            .disabled(editor.usesNullKey)
                            .accessibilityIdentifier("kafkaProduceKey")
                        if editor.keyIsBase64 { Text("Base64").font(.caption).foregroundStyle(.secondary) }
                        Toggle("NULL", isOn: $editor.usesNullKey).fixedSize()
                    }
                }
            }.formStyle(.columns).textFieldStyle(.roundedBorder).padding(16)
                .disabled(editor.isSending || editor.needsSource)
            HStack(spacing: 12) {
                Picker(copy.text("内容", "Content"), selection: $showsHeaders) {
                    Text("Value").tag(false)
                    Text("Headers (\(editor.headers.count))").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                Spacer()
                if showsHeaders {
                    Button(copy.text("添加 Header", "Add Header"), systemImage: "plus") {
                        editor.headers.append(.init())
                    }.disabled(editor.headers.count >= 100)
                } else {
                    Toggle("NULL", isOn: $editor.usesNullValue).fixedSize()
                    Picker(copy.text("格式", "Format"), selection: $editor.format) {
                        Text("JSON").tag(WorkspaceKafkaProducerModel.Format.json)
                        Text(copy.text("文本", "Text")).tag(WorkspaceKafkaProducerModel.Format.text)
                        Text("Base64").tag(WorkspaceKafkaProducerModel.Format.base64)
                    }.frame(width: 145).disabled(editor.usesNullValue)
                    Button(copy.text("格式化", "Format")) { editor.formatJSON() }
                        .disabled(!editor.isJSON || editor.usesNullValue)
                }
            }.padding(.horizontal, 16).padding(.bottom, 12).disabled(editor.isSending || editor.needsSource)
            Divider()
            Group {
                if showsHeaders {
                    ScrollView {
                        VStack(spacing: 10) {
                            if editor.headers.isEmpty {
                                Text(copy.text("没有 Headers", "No headers")).foregroundStyle(.secondary).padding(24)
                            }
                            ForEach(editor.headers) { header in
                                WorkspaceKafkaProducerHeaderRow(header: header, editor: editor)
                            }
                        }.textFieldStyle(.roundedBorder).padding(16)
                    }
                } else if editor.isJSON {
                    WorkspaceJSONTextView(text: $editor.value, isEditable: true,
                        accessibilityLabel: copy.text("Kafka 消息 JSON 编辑器", "Kafka message JSON editor"))
                } else {
                    TextEditor(text: $editor.value).font(.system(.body, design: .monospaced))
                        .accessibilityLabel(copy.text("Kafka 消息文本编辑器", "Kafka message text editor"))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .disabled(editor.isSending || editor.needsSource || (!showsHeaders && editor.usesNullValue))
            WorkspaceDatabaseDataProgressBar(isActive: editor.isSending || editor.isLoadingSource)
            Divider()
            HStack(spacing: 12) {
                status.frame(maxWidth: .infinity, alignment: .leading)
                if editor.needsSource && !editor.isLoadingSource {
                    Button(copy.text("重试", "Retry")) {
                        operation = Task { await editor.loadSource { try await workspace.kafkaMessageForCopy($0) } }
                    }
                }
                Button(copy.text("关闭", "Close"), action: close)
                    .keyboardShortcut(.cancelAction).disabled(editor.isSending)
                Button(copy.text("发送", "Send")) {
                    operation = Task { await editor.send { try await workspace.produceKafkaMessage($0) } }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(editor.isSending || workspace.safetyLock.isEnabled || editor.validationMessage != nil)
                .accessibilityIdentifier("kafkaProduceSend")
            }.padding(16).frame(height: 76)
        }
        .frame(minWidth: 760, idealWidth: 980, maxWidth: .infinity,
               minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        .alert(copy.text("停用安全锁？", "Disable Safety Lock?"), isPresented: $showsUnlock) {
            Button(copy.text("允许此工作区进行更改", "Allow Changes for This Workspace"), role: .destructive) {
                workspace.safetyLock.disable()
            }
            Button(copy.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(copy.text("停用后可向当前工作区发送 Kafka 消息。", "Disabling the lock allows Kafka messages to be sent in this workspace."))
        }
        .onDisappear { operation?.cancel() }
        .task { await editor.loadSource { try await workspace.kafkaMessageForCopy($0) } }
    }

    @ViewBuilder private var status: some View {
        if editor.needsSource {
            if let error = editor.error {
                Text(error).foregroundStyle(.red).lineLimit(2).help(error)
            } else {
                Text(copy.text("正在读取原始消息…", "Reading original message…")).foregroundStyle(.secondary)
            }
        } else if editor.isSending {
            Text(copy.text("正在发送…", "Sending…")).foregroundStyle(.secondary)
        } else if workspace.safetyLock.isEnabled {
            HStack {
                Label(copy.text("安全锁已启用", "Safety lock enabled"), systemImage: "lock").foregroundStyle(.secondary)
                Button(copy.text("停用安全锁…", "Disable Safety Lock…")) { showsUnlock = true }
            }
        } else if let error = editor.error ?? editor.validationMessage {
            Text(error).foregroundStyle(.red).lineLimit(2).help(error)
        } else if let receipt = editor.receipt {
            let offset = receipt.offset.map(String.init) ?? copy.text("不可用", "Unavailable")
            Label(copy.text("发送成功 · 分区 \(receipt.partition) · Offset \(offset)",
                            "Sent · Partition \(receipt.partition) · Offset \(offset)"), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).textSelection(.enabled)
        } else {
            Text(copy.text("⌘↩ 发送 · 最大 1 MB", "⌘↩ Send · Up to 1 MB")).foregroundStyle(.secondary)
        }
    }
}

struct WorkspaceKafkaProducerHeaderRow: View {
    let header: WorkspaceKafkaProducerModel.Header
    let editor: WorkspaceKafkaProducerModel

    var body: some View {
        HStack {
            TextField(AppCopy.current.text("名称", "Name"), text: binding(for: \.name)).frame(width: 220)
            TextField(AppCopy.current.text("值", "Value"), text: binding(for: \.value))
                .disabled(header.usesNullValue)
            if header.isBase64 { Text("Base64").font(.caption).foregroundStyle(.secondary) }
            Toggle("NULL", isOn: binding(for: \.usesNullValue)).fixedSize()
            Button(AppCopy.current.text("移除 Header", "Remove Header"), systemImage: "minus.circle", action: remove)
                .labelStyle(.iconOnly)
        }
    }

    func remove() { editor.removeHeader(id: header.id) }

    func binding<Value>(for field: WritableKeyPath<WorkspaceKafkaProducerModel.Header, Value>) -> Binding<Value> {
        // Text fields may finish editing after their row has been removed.
        // Resolve by stable identity; a stale binding must not edit a shifted row.
        Binding(
            get: { (editor.headers.first { $0.id == header.id } ?? header)[keyPath: field] },
            set: { editor.updateHeader(id: header.id, field: field, value: $0) }
        )
    }
}
