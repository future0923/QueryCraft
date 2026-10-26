import SwiftUI
import UIKit
import QueryCraftMobileCore

struct MobileElasticsearchActionView: View {
    @Bindable var action: MobileElasticsearchAction
    @State private var discard = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MobileFormStatus(message: action.isSubmitting ? "正在等待服务器回执…" : action.isBusy ? "处理中…" : action.hasLoaded ? "" : "尚未加载，请重试",
                        isBusy: action.isBusy, isError: !action.hasLoaded && !action.isBusy)
                }
                Section("目标") {
                    LabeledContent("连接", value: action.owner.profile.name)
                    LabeledContent("服务器", value: action.owner.profile.host + ":" + String(action.owner.profile.port))
                    if let object = action.object {
                        LabeledContent("资源", value: object.name)
                        Text(object.kind == .elasticsearchIndex ? "索引" : object.kind == .elasticsearchAlias ? "Alias" : "Data Stream").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Group {
                    switch action.kind {
                    case .document: document
                    case .cellChanges:
                        Section("已暂存字段") {
                            ForEach(action.owner.cellChanges.order, id: \.self) { reference in
                                Text(reference.index + "/" + reference.id)
                                if let entry = action.owner.cellChanges.entries[reference] { Text(entry.sourceText ?? "正在校验…").font(.caption.monospaced()).lineLimit(8); if let error = entry.error { Text(error).foregroundStyle(.red) } }
                            }
                            Button("撤销全部字段修改", role: .destructive) { action.discardCellChanges() }
                        }
                    case .batchDelete:
                        Section("当前页文档") {
                            Button("选择当前页全部") { action.selectedRows = Set(0..<(action.owner.page?.rowCount ?? 0)) }
                            Button("清除选择") { action.selectedRows = [] }
                            ForEach(action.owner.page?.rows ?? [], id: \.id) { row in
                                if let reference = action.owner.documentReference(row: row, columns: action.owner.page?.columns ?? []) {
                                    let index = row.id - (action.owner.page?.offset ?? 0)
                                    Toggle(reference.index + "/" + reference.id, isOn: Binding(get: { action.selectedRows.contains(index) }, set: { if $0 { action.selectedRows.insert(index) } else { action.selectedRows.remove(index) } }))
                                }
                            }
                            Text("每篇文档使用独立版本条件；批量删除不是事务，错误后停止且不会回滚已删除的文档。").font(.caption)
                        }
                    case .createDocument:
                        Section("文档标识") { input("_id（留空由服务器生成）", text: $action.documentID); input("routing（可选）", text: $action.routing) }
                        jsonEditor("_source", text: $action.source)
                    case .pasteDocuments:
                        Section { Button("从剪贴板粘贴") { if let text = UIPasteboard.general.string { action.source = text } }; Text("粘贴含字段表头的 CSV / TSV；复用桌面类型转换，最多 500 篇、8 MiB，每篇最多 1 MiB。逐篇创建，发生错误时停止，已成功的文档不会回滚。") }
                        jsonEditor("CSV / TSV", text: $action.source)
                    case .mapping: mapping
                    case .createIndex:
                        Section("索引") { input("索引名称", text: $action.name); input("主分片数（默认留空）", text: $action.shards); input("副本数（默认留空）", text: $action.replicas) }
                        jsonEditor("初始 Mapping", text: $action.source)
                    case .deleteIndex:
                        Section { Text("将永久删除索引及全部文档。仅支持普通索引；提交前再次核对，服务器不提供索引删除的原子版本保护。").foregroundStyle(.red); input("输入完整索引名称", text: $action.name) }
                    case .settings:
                        if let snapshot = action.settings {
                            Section("统计") {
                                LabeledContent("文档数", value: snapshot.documentCount.map(String.init) ?? "不可用")
                                LabeledContent("存储字节数", value: snapshot.storeBytes.map(String.init) ?? "不可用")
                                LabeledContent("健康", value: snapshot.health ?? "不可用")
                                ForEach(snapshot.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            }
                        }
                        Section("动态设置") {
                            input("副本数", text: $action.replicas); input("refresh_interval，例如 1s 或 -1", text: $action.secondary)
                            Text("提交前复核索引 UUID 和原设置；Settings API 不支持原子 CAS。").font(.caption)
                        }.disabled(action.settings?.editableIndex == nil)
                        rawResponse
                    case .aliases: aliases
                    case .templates: templates
                    case .simulate:
                        Section("模拟未来索引") { input("具体索引名称", text: $action.name); Button("模拟（只读）") { action.simulate() }.disabled(action.isBusy || !action.hasLoaded) }
                        rawResponse
                    }
                }.disabled(action.isBusy || action.needsVerification || action.completed)
                if action.kind != .simulate {
                    if !action.completed, !action.needsVerification {
                        Section("提交") {
                            Toggle("安全锁", isOn: Binding(get: { action.owner.safetyLock.isEnabled }, set: { $0 ? action.owner.safetyLock.enable() : action.owner.safetyLock.disable() }))
                                .disabled(action.isBusy)
                            Button("预览完整请求") { action.prepare() }.disabled(action.isBusy || !action.hasLoaded)
                            if let preview = action.preview {
                                MobileElasticsearchText(text: preview)
                                if action.owner.fullscreenAction !== action { Button("在 REST 控制台查看此请求") { action.openInConsole() } }
                                Button("确认执行以上请求", role: .destructive) { action.submit() }.disabled(!action.canSubmit).accessibilityIdentifier("confirmElasticsearchWrite")
                            }
                        }
                    }
                    if action.needsVerification {
                        Section("结果待核实") {
                            Text("禁止重发本次写入；读取当前状态不能证明原操作成功。").foregroundStyle(.red)
                            Button("只读核实服务器状态") { action.verify() }.disabled(action.isBusy || action.isBackgrounded)
                            MobileElasticsearchText(text: action.raw)
                            Button("已核对服务器，结束本次操作") { action.finishVerification() }.disabled(!action.verified || action.isBusy)
                        }
                    }
                }
                if !action.acknowledgedWrites.isEmpty { Section("已收到成功回执的操作") { MobileElasticsearchText(text: action.acknowledgedWrites.joined(separator: "\n")) } }
                if let message = action.message { Section { Text(message).textSelection(.enabled).foregroundStyle(action.completed ? Color.secondary : .red) } }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(action.kind.title).navigationBarTitleDisplayMode(.inline)

            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(action.completed ? "完成" : "关闭") { if action.completed || action.kind == .simulate { action.close() } else { discard = true } }.disabled(action.isBusy || action.needsVerification) }
                ToolbarItem(placement: .primaryAction) { Button("重新读取", systemImage: "arrow.clockwise") { discard = true }.disabled(action.isBusy || action.needsVerification || action.completed) }
            }
            .confirmationDialog("放弃当前草稿？", isPresented: $discard, titleVisibility: .visible) {
                Button("放弃并关闭", role: .destructive) { action.close() }
                Button("放弃并重新读取", role: .destructive) { action.reload() }
                Button("取消", role: .cancel) {}
            }
        }.interactiveDismissDisabled(!action.completed)
    }
    private var document: some View {
        Group {
            if let snapshot = action.document {
                Section("服务器标识") {
                    LabeledContent("_index", value: snapshot.reference.index); LabeledContent("_id", value: snapshot.reference.id)
                    LabeledContent("routing", value: snapshot.reference.routing ?? "—")
                    LabeledContent("_version", value: snapshot.version.map(String.init) ?? "—")
                    LabeledContent("_score", value: snapshot.score.map { String($0) } ?? "—")
                    LabeledContent("seq_no / primary_term", value: "\(snapshot.sequenceNumber.map(String.init) ?? "—") / \(snapshot.primaryTerm.map(String.init) ?? "—")")
                    if snapshot.isTruncated { Text("超过完整编辑上限，当前只读预览。").foregroundStyle(.red) }
                }
                Section {
                    Picker("操作", selection: $action.mode) { Text("替换 _source").tag("replace"); Text("局部更新 doc").tag("partial"); Text("删除文档").tag("delete") }
                    if action.mode == "partial" { Text("仅提交下方 JSON 对象内的字段；更新嵌套对象按 Elasticsearch 的合并规则执行。") }
                    if action.mode == "delete" { Text("删除使用当前 seq_no / primary_term；外部更新会拒绝本次删除。").foregroundStyle(.red) }
                }.disabled(snapshot.isTruncated)
                Section("暂存字段修改") {
                    Menu(action.fieldName.isEmpty ? "选择字段" : action.fieldName) {
                        ForEach((action.owner.page?.columns ?? []).filter { column in WorkspaceElasticsearchDocumentCellEditor.canEdit(fieldName: column.name) && action.owner.mapping?.fieldCapabilities.first(where: { field in field.path == column.name })?.hasTypeConflict != true }) { column in Button(column.name) { action.loadField(column.name) } }
                    }
                    Toggle("NULL", isOn: $action.fieldNull)
                    MobileSegmentedTextEditor(text: $action.fieldText, accessibilityIdentifier: "elasticsearchFieldInput").disabled(action.fieldNull)
                    Button("暂存此字段") { action.stageField() }.disabled(action.fieldName.isEmpty || snapshot.isTruncated)
                    Text("字符串、数字、布尔、数组、对象和 null 沿桌面输入规则；以引号包裹可明确输入 JSON 字符串。").font(.caption)
                }
                if action.mode != "delete" { jsonEditor(action.mode == "partial" ? "changed fields" : "_source", text: $action.source) }
                ShareLink(snapshot.isTruncated ? "分享当前 _source 预览（非完整文档）" : "分享服务器完整 _source", item: String(decoding: snapshot.sourceJSON, as: UTF8.self))
            }
        }
    }
    private var mapping: some View {
        Group {
            Section("字段") {
                Menu("选择已有字段") { ForEach(action.mapping?.fields ?? [], id: \.path) { node in Button(node.displayPath) { action.selectMappingField(node) } } }
                Toggle("新建字段", isOn: $action.mappingIsNew)
                input("字段路径（JSON 数组）", text: $action.mappingPath)
                Text("嵌套字段继续添加 properties，多字段使用 fields；路径逐段保留原始名称。已有字段只允许服务器及桌面支持的参数，不允许改类型或删除。").font(.caption)
            }
            jsonEditor("字段定义 JSON", text: $action.source)
            rawResponse
        }
    }
    private var aliases: some View {
        Group {
            Section("当前绑定") {
                ForEach(action.aliasRows) { row in
                    VStack(alignment: .leading) {
                        Text(row.binding.indexName + " → " + row.binding.aliasName).lineLimit(2)
                        Text(String(decoding: row.binding.optionsJSON, as: UTF8.self)).font(.caption.monospaced()).lineLimit(3)
                        Picker("写入索引", selection: Binding(get: { row.binding.isWriteIndex.map { $0 ? "yes" : "no" } ?? "default" }, set: { action.updateAlias(row.id, writeIndex: $0) })) { Text("服务器默认").tag("default"); Text("是").tag("yes"); Text("否").tag("no") }
                        Button(row.isRemoved ? "恢复绑定" : "移除绑定", role: .destructive) { action.toggleAlias(row.id) }
                    }.opacity(row.isRemoved ? 0.5 : 1)
                }
            }
            Section("添加绑定") {
                input("索引名称", text: $action.secondary); input("Alias 名称", text: $action.name)
                jsonEditor("高级选项 JSON（filter / routing 等）", text: $action.source)
                Button("暂存添加") { action.addAlias() }
                Text("原有 filter、routing 等选项完整保留；提交前复查绑定，Alias API 没有 CAS。").font(.caption)
            }
            rawResponse
        }
    }
    private var templates: some View {
        Group {
            Section("模板列表") {
                TextField("搜索模板名称或匹配模式", text: $action.templateSearch).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("新建模板") { action.selectTemplate(nil) }
                ForEach(action.visibleTemplates) { template in
                    Button { action.selectTemplate(template) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(template.name)
                            Text(template.indexPatterns.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            Section("模板") {
                input("模板名称", text: $action.name).disabled(action.templateBaseline != nil)
                if action.templateBaseline != nil { Picker("操作", selection: $action.mode) { Text("保存").tag("save"); Text("删除").tag("delete") } }
                Text("支持 index_patterns、priority、composed_of、data_stream、settings、mappings 和 aliases；完整 JSON 沿桌面校验，提交前复核基线。").font(.caption)
            }
            if action.mode != "delete" { jsonEditor("模板 JSON", text: $action.source) }
        }
    }
    private var rawResponse: some View {
        DisclosureGroup("服务器完整响应") { MobileElasticsearchText(text: action.raw); ShareLink("分享响应", item: action.raw) }
    }
    private func input(_ title: String, text: Binding<String>) -> some View { LabeledContent(title) { TextField("请输入", text: text).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() } }
    private func jsonEditor(_ title: String, text: Binding<String>) -> some View { Section(title) { MobileSegmentedTextEditor(text: text, accessibilityIdentifier: "elasticsearchActionSource") } }
}

struct MobileElasticsearchText: View {
    let text: String
    @State private var offset = 0
    private var segment: MobileTextSegment { .range(in: text, offset: offset) }
    var body: some View {
        VStack(alignment: .leading) {
            if text.utf8.count > 65_536 {
                HStack { Button("从头") { offset = 0 }; Spacer(); Text("偏移 \(offset)").font(.caption); Button("下一段") { let value = segment; offset = text.utf8.distance(from: text.utf8.startIndex, to: value.end) }.disabled(segment.end == text.utf8.endIndex) }
            }
            Text(segment.text(in: text)).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.onChange(of: text) { _, _ in offset = 0 }
    }
}
