import SwiftUI
import UniformTypeIdentifiers

struct MobileDataImportView: View {
    @Bindable var model: MobileDataImportModel
    let close: () -> Void
    let discard: () -> Void
    @State private var choosing = false
    @State private var unlock = false
    @State private var ending = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MobileFormStatus(message: model.message ?? (model.isLoading ? "正在读取和校验…" : "CSV / TSV / JSON / XLSX / SQL INSERT"),
                        isBusy: model.isLoading || model.isRunning, isError: model.message != nil)
                }
                Section("目标") {
                    LabeledContent("服务器", value: model.configuration.host + ":" + String(model.configuration.port))
                    LabeledContent("数据库", value: model.object.database)
                    LabeledContent("Schema", value: model.object.schemaName ?? "—")
                    LabeledContent("表", value: model.object.name)
                }
                if model.outcome == nil || model.outcome?.status == .failed || model.outcome?.status == .cancelled {
                    Section("来源与选项") {
                        Button(model.fileURL?.lastPathComponent ?? "选择文件…") { choosing = true }.disabled(!model.canEdit)
                        Picker("格式", selection: Binding(get: { model.options.format }, set: { model.setFormat($0) })) {
                            ForEach(WorkspaceDataImportFormat.allCases) { Text($0.title).tag($0) }
                        }
                        if model.options.format != .excel {
                            Picker("编码", selection: $model.options.encoding) { ForEach(WorkspaceDataImportOptions.Encoding.allCases) { Text($0.title).tag($0) } }
                        }
                        if model.options.format.isDelimited { MobileSchemaTextField(title: "分隔符", text: $model.options.delimiter) }
                        if model.options.format == .excel {
                            if let names = model.file?.sheetNames, !names.isEmpty {
                                Picker("工作表", selection: $model.options.sheetIndex) { ForEach(Array(names.enumerated()), id: \.element) { item in Text(item.element).tag(item.offset) } }
                            } else { Stepper("工作表序号：\(model.options.sheetIndex + 1)", value: $model.options.sheetIndex, in: 0...999) }
                            Text("读取公式缓存结果，不执行公式或宏。旧版 XLS 请先另存为 XLSX。").font(.caption).foregroundStyle(.secondary)
                        }
                        if model.options.format.usesRows {
                            integer("标题行（0 为无）", value: $model.options.headerRow)
                            integer("数据起始行", value: $model.options.firstDataRow)
                            integer("最后行（0 为末尾）", value: $model.options.lastDataRow)
                            Toggle("去除前后空白", isOn: $model.options.trimsWhitespace)
                            Toggle("空字符串作为 NULL", isOn: $model.options.emptyAsNull)
                        }
                        if model.options.format.isDelimited || model.options.format == .excel { MobileSchemaTextField(title: "NULL 标记", text: $model.options.nullToken) }
                        if model.options.format == .sql {
                            Toggle("MySQL 反斜杠转义", isOn: $model.options.sqlBackslashEscapes)
                            Text("仅解析同一表的 INSERT VALUES 字面量，重新映射到当前目标；不执行原始脚本。").font(.caption).foregroundStyle(.secondary)
                        }
                        Stepper("预览行数：\(model.options.previewRows)", value: $model.options.previewRows, in: 10...200, step: 10)
                        Button(model.file == nil ? "读取文件与表结构" : "重新读取预览") { model.load() }.disabled(!model.canEdit || model.fileURL == nil)
                    }.disabled(!model.canEdit)
                    if let file = model.file, let schema = model.schema {
                        Section("字段映射 · 共 \(file.rowCount) 行") {
                            ForEach(Array(file.columns.enumerated()), id: \.element) { item in
                                let index = item.offset
                                Picker(file.columns[index], selection: Binding(get: { model.mapping[index] ?? "" }, set: { model.mapping[index] = $0.isEmpty ? nil : $0 })) {
                                    Text("忽略").tag("")
                                    ForEach(schema.writableColumns, id: \.name) { Text($0.name + " · " + $0.type).tag($0.name) }
                                }
                            }
                            integer("每批行数", value: $model.batchSize)
                            Button("校验并预览导入") { model.prepare() }.disabled(!model.canEdit || !model.hasCurrentPreview)
                            if !model.hasCurrentPreview { Text("选项或读取状态已变化，请重新读取预览。").font(.caption).foregroundStyle(.secondary) }
                        }.disabled(!model.canEdit)
                        Section("文件预览（前 \(min(file.previewRows.count, model.options.previewRows)) 行，长值仅预览）") {
                            ForEach(model.previewRows) { row in
                                DisclosureGroup("第 \(row.number) 行") {
                                    ForEach(Array(file.columns.enumerated()), id: \.element) { column in
                                        LabeledContent(column.element, value: row.cells[column.offset] ?? "NULL")
                                    }
                                }
                            }
                        }
                    }
                    if model.prepared != nil {
                        Section("确认导入") {
                            Text("\(model.file?.rowCount ?? 0) 行；全部批次在同一事务执行，失败回滚。以下仅为首行示例，实际使用完整值。")
                            Text(model.exampleSQL ?? "").font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                            Button("开始导入", role: .destructive) {
                                if model.safetyLock.isEnabled { unlock = true } else { model.run() }
                            }.disabled(!model.canEdit)
                        }
                    }
                }
                if model.isRunning || model.outcome != nil {
                    Section("执行") {
                        Text(model.outcome?.message ?? (model.isCancelling ? "正在停止并回滚…" : "正在导入…"))
                        LabeledContent("已处理", value: "\(model.completedRows) / \(model.file?.rowCount ?? 0)")
                        if model.isRunning { Button("取消导入", role: .destructive) { model.cancel() }.disabled(model.isCancelling) }
                        if model.needsVerification { Button("已核对服务器，结束此次操作", role: .destructive) { ending = true } }
                    }
                }
                if !model.isRunning && !model.needsVerification { Section { Button("丢弃导入草稿", role: .destructive) { ending = true } } }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("导入 PostgreSQL 数据").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("保留并关闭", action: close).disabled(model.isRunning) } }

            .fileImporter(isPresented: $choosing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                do { if let url = try result.get().first { model.select(url) } } catch { model.message = error.localizedDescription }
            }
            .alert("解锁并执行已预览的导入？", isPresented: $unlock) {
                Button("取消", role: .cancel) {}
                Button("解锁并导入", role: .destructive) { model.safetyLock.disable(); model.run() }
            } message: { Text("目标：\(model.object.database) / \(model.object.displayName)，\(model.file?.rowCount ?? 0) 行。") }
            .alert(model.needsVerification ? "确认已核对服务器？" : "丢弃导入草稿？", isPresented: $ending) {
                Button("取消", role: .cancel) {}; Button("结束", role: .destructive, action: discard)
            } message: { Text(model.needsVerification ? "不会重复执行导入。请先核对服务器中的实际数据。" : "已读取的文件快照和字段映射将释放。") }
            .interactiveDismissDisabled(model.isRunning)
            .onDisappear { model.cancelRead() }
        }
    }
    private func integer(_ title: String, value: Binding<Int>) -> some View {
        LabeledContent(title) { TextField(title, value: value, format: .number).multilineTextAlignment(.trailing).keyboardType(.numberPad) }
    }
}
