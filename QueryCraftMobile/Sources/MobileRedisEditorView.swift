import SwiftUI
import QueryCraftMobileCore
import UniformTypeIdentifiers

struct MobileRedisEditorView: View {
    @Bindable var editor: MobileRedisEditor
    let close: () -> Void
    @State private var confirmDiscard = false
    @State private var confirmReload = false
    @State private var exportData = Data()
    @State private var isExportingString = false
    @State private var exportFilename = "redis-value.bin"
    @State private var commandExportRequest: Bool?
    @State private var rawExportRequest: UUID?
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    Section("DB \(editor.database) · \(editor.snapshot?.details.reference.type.rawValue ?? "Redis")") {
                        Text(editor.key).lineLimit(3).truncationMode(.middle).textSelection(.enabled)
                        Toggle("安全锁", isOn: Binding(get: { editor.safetyLock.isEnabled }, set: { if $0 { editor.safetyLock.enable() } else { editor.safetyLock.disable() } }))
                            .disabled(editor.isSubmitting || editor.isBackgrounded)
                    }
                    if let snapshot = editor.snapshot {
                        if !editor.searchState.availableFields(for: snapshot.details.reference.type).isEmpty {
                            MobileRedisMemberSearchView(editor: editor, state: editor.searchState, type: snapshot.details.reference.type)
                        }
                        if snapshot.isPartial {
                            Section {
                                HStack {
                                    Button("上一页") { editor.previousPage() }.disabled(!editor.canTurnPage || editor.pageNumber == 1)
                                    Spacer()
                                    Text("第 \(editor.pageNumber) 页 · 键共 \(snapshot.count) 项").font(.caption)
                                    Spacer()
                                    Button("下一页") { editor.nextPage() }.disabled(!editor.canTurnPage || snapshot.continuation == nil)
                                }
                                Text("先提交或丢弃本页草稿再翻页。SCAN 非稳定快照，成员可能重复或变化；本页不提供整键 TTL 修改和删除。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if snapshot.details.reference.type == .string {
                            Section("字符串") {
                                Toggle("HEX 字节编辑", isOn: Binding(get: { editor.usesHex }, set: { editor.switchFormat($0) }))
                                HStack {
                                    Button(editor.jsonPresentation == nil ? "JSON 展示" : "原文展示") { editor.toggleJSONPresentation() }.disabled(editor.usesHex || editor.isFormattingString || editor.isValidatingString)
                                    Spacer()
                                    Button("导出原始字节") { rawExportRequest = UUID() }.disabled(editor.isValidatingString)
                                }
                                Button("导出整键命令") { commandExportRequest = false }.disabled(!editor.canEdit || editor.isValidatingString)
                                if editor.usesStringSegments {
                                    HStack {
                                        Button("上一段", action: editor.previousStringSegment).disabled(!editor.canGoToPreviousStringSegment)
                                        Spacer()
                                        Text("展示偏移 \(editor.stringPageOffset)").font(.caption)
                                        Spacer()
                                        Button("下一段", action: editor.nextStringSegment).disabled(!editor.canGoToNextStringSegment)
                                    }
                                    Text("大值按约 32 KiB 分段展示；草稿保留完整内容，保存时校验并写入完整值。").font(.caption).foregroundStyle(.secondary)
                                }
                                TextEditor(text: Binding(get: { editor.stringEditorText }, set: { editor.updateStringEditorText($0) })).font(.system(.body, design: .monospaced)).frame(minHeight: 180)
                                    .accessibilityIdentifier("redisStringEditor")
                            }.disabled(!editor.canEdit || editor.deleteKey)
                        } else {
                            Section("\(snapshot.details.reference.type.rawValue) 成员") {
                                if editor.rows.isEmpty && !editor.isLoading {
                                    Text(editor.activeSearch == nil ? "当前页没有成员。" : "当前搜索页没有匹配成员。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach($editor.rows) { $row in
                                    VStack(alignment: .leading, spacing: 8) {
                                        if snapshot.details.reference.type == .list {
                                            Text(row.originalIndex.map { "位置 \($0)" } ?? (row.insertionEdge == .head ? "新增到头部" : "新增到尾部")).font(.caption)
                                        } else {
                                            TextField(snapshot.details.reference.type == .hash ? "字段" : "成员", text: $row.firstValue).disabled(row.isBinaryReadOnly)
                                        }
                                        if snapshot.details.reference.type != .set {
                                            TextField(snapshot.details.reference.type == .sortedSet ? "分数" : "值", text: $row.secondValue, axis: .vertical).disabled(row.isBinaryReadOnly)
                                        }
                                        if snapshot.details.reference.type == .hash, snapshot.hashFieldExpirationSupport == true {
                                            TextField("字段 TTL（毫秒，留空为永久）", text: $row.thirdValue).keyboardType(.numberPad).disabled(row.isBinaryReadOnly)
                                        }
                                        if row.isBinaryReadOnly { Text("二进制成员保留原始字节，暂不支持移动端修改。").font(.caption) }
                                        HStack {
                                            Button { editor.toggleSelection(row.id) } label: {
                                                Image(systemName: editor.selectedRowIDs.contains(row.id) ? "checkmark.circle.fill" : "circle")
                                            }.accessibilityLabel(editor.selectedRowIDs.contains(row.id) ? "取消选择成员" : "选择成员")
                                            Spacer()
                                        Button(row.isDeleted ? "撤销删除" : "删除成员", role: row.isDeleted ? nil : .destructive) { editor.removeRow(row.id) }
                                            .disabled(row.isBinaryReadOnly)
                                        }
                                    }.opacity(row.isDeleted ? 0.5 : 1)
                                }
                                if snapshot.details.reference.type == .hash {
                                    Text(snapshot.hashFieldExpirationSupport == true
                                         ? "字段 TTL 留空可移除过期时间。修改字段值遵循 HSET，会清除字段 TTL；重命名按当前 TTL 时长重新计时。"
                                         : snapshot.hashFieldExpirationSupport == false ? "服务器不支持 Hash 字段 TTL。" : "字段 TTL 能力探测失败或无权限，未将未知状态视为永久。")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button("添加成员") { editor.addRow() }
                                    if snapshot.details.reference.type == .list { Button("添加到头部") { editor.addRow(head: true) } }
                                    Spacer()
                                    Menu {
                                        Button("选择本页全部", action: editor.selectAllRows)
                                        Button("取消选择", action: editor.clearSelection)
                                        Button("删除所选成员", role: .destructive, action: editor.removeSelectedRows).disabled(editor.selectedRowIDs.isEmpty)
                                        Button("导出所选命令") { commandExportRequest = true }.disabled(editor.selectedRowIDs.isEmpty)
                                        Button("导出整键命令") { commandExportRequest = false }.disabled(snapshot.isPartial || editor.activeSearch != nil)
                                    } label: { Label("成员操作", systemImage: "ellipsis.circle") }
                                }
                            }.disabled(!editor.canEdit || editor.deleteKey)
                        }
                        Section("过期时间") {
                            Picker("到期方式", selection: $editor.expirationMode) {
                                ForEach(RedisKeyExpirationMode.allCases) { Text($0.title).tag($0) }
                            }
                            TextField("TTL（毫秒，正整数）", text: $editor.ttl).keyboardType(.numberPad)
                                .disabled(editor.expirationMode == .persistent)
                            Text("未修改 TTL 时保留原到期时间；新 TTL 从提交时开始计算。").font(.caption).foregroundStyle(.secondary)
                        }.disabled(!editor.canEdit || editor.deleteKey || snapshot.isPartial)
                        Section {
                            Toggle("删除整个键", isOn: $editor.deleteKey).tint(.red)
                            if editor.deleteKey { Text("将删除整个键及全部成员；其他草稿改动不会提交。").font(.caption).foregroundStyle(.red) }
                        }.disabled(!editor.canEdit || snapshot.isPartial)
                    }
                    Section {
                        Button("预览改动") { editor.prepare() }.disabled(!editor.canEdit || editor.isValidatingString || editor.safetyLock.isEnabled)
                            .accessibilityIdentifier("redisPreviewChanges")
                    }
                    if let preview = editor.preview {
                        Section("确认命令 · DB \(editor.database)") {
                            Text(String(preview.prefix(65_536))).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            if preview.contains("预览已截断") || preview.count > 65_536 {
                                Text("大参数或长命令仅展示有界预览。保存仍使用完整原始字节；请核对编辑内容及导出的原始值。").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("提交前核对原值；冲突会中止。Redis 事务执行期错误可能使部分命令生效。").font(.caption).foregroundStyle(.secondary)
                            Button("确认提交", role: editor.deleteKey ? .destructive : nil) { editor.submit() }
                                .id("redisConfirmation")
                                .disabled(!editor.canSubmit).accessibilityIdentifier("redisConfirmChanges")
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: editor.preview) { _, value in
                    if value != nil { proxy.scrollTo("redisConfirmation", anchor: .bottom) }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).opacity(editor.isLoading || editor.isSubmitting || editor.isPreparingExport || editor.isValidatingString || editor.isFormattingString ? 1 : 0)
                    Text(editor.message ?? (editor.isSubmitting ? "正在提交…" : editor.isLoading ? "正在读取…" : editor.isValidatingString ? "正在校验完整 String 字节…" : "修改后先预览，再确认提交。"))
                        .font(.caption).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    if editor.needsVerification || editor.message != nil {
                        Button(editor.needsVerification ? "读取核实" : "重新读取") { confirmReload = true }
                            .disabled(editor.isSubmitting || editor.isLoading || editor.isBackgrounded)
                    }
                }.padding(.horizontal, 16).frame(height: 64).background(.bar)
            }
            .navigationTitle("编辑 Redis 键").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("完成") { if editor.hasChanges { confirmDiscard = true } else { close() } }.disabled(!editor.canClose)
            } }
            .confirmationDialog("放弃尚未提交的草稿？", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("放弃草稿并关闭", role: .destructive, action: close)
            }
            .confirmationDialog("重新读取会丢弃当前草稿，不会重放写命令。", isPresented: $confirmReload, titleVisibility: .visible) {
                Button("丢弃草稿并重新读取", role: .destructive) { editor.reload(discard: true) }
            }
        }.interactiveDismissDisabled()
        .task(id: rawExportRequest) {
            guard rawExportRequest != nil else { return }
            if let data = await editor.rawStringExport(), !Task.isCancelled {
                exportData = data; exportFilename = "redis-value.bin"; isExportingString = true
            }
            rawExportRequest = nil
        }
        .task(id: commandExportRequest) {
            guard let selectedOnly = commandExportRequest else { return }
            if let data = await editor.commandExport(selectedOnly: selectedOnly), !Task.isCancelled {
                exportData = data; exportFilename = "redis-commands.redis"; isExportingString = true
            }
            commandExportRequest = nil
        }
        .fileExporter(isPresented: $isExportingString, document: MobileRedisBinaryDocument(data: exportData), contentType: .data, defaultFilename: exportFilename) { result in
            if case .failure(let error) = result { editor.exportFailed(error) }
        }
    }
}

struct MobileRedisBinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: data) }
}
