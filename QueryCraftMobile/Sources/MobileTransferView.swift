import SwiftUI
import QueryCraftMobileCore

struct MobileTransferView: View {
    @Bindable var model: MobileTransferModel
    @Environment(\.dismiss) private var dismiss
    @State private var history = false
    @State private var saved = false
    @State private var password = ""
    @State private var discardTask: SavedTransferTask?
    @State private var changingTask = false
    @ScaledMetric(relativeTo: .caption) private var statusHeight: CGFloat = 48
    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("任务名称", text: $model.taskName)
                    HStack {
                        Button("保存配置", systemImage: "square.and.arrow.down") { model.saveTask() }
                        Spacer()
                        Button("已保存任务", systemImage: "folder") { saved = true }
                    }
                }
                endpoint(.source, title: "来源")
                endpoint(.target, title: "目标")
                Section("传输选项") {
                    Picker("内容", selection: $model.configuration.content) { ForEach(TransferContent.allCases) { Text($0.title).tag($0) } }
                    Picker("已有对象", selection: $model.configuration.strategy) { ForEach(TransferStrategy.allCases) { Text($0.title).tag($0) } }
                    Picker("名称大小写", selection: $model.configuration.nameCase) { ForEach(TransferNameCase.allCases) { Text($0.title).tag($0) } }
                    Picker("所有者", selection: $model.ownership) { ForEach(TransferOwnership.allCases) { Text($0.title).tag($0) } }
                    Stepper("每批 \(model.configuration.batchSize) 行", value: $model.configuration.batchSize, in: 100...10000, step: 100)
                    Toggle("指定操作超时", isOn: Binding(get: { model.configuration.operationTimeoutSeconds != nil }, set: { model.configuration.operationTimeoutSeconds = $0 ? 60 : nil }))
                    if model.configuration.operationTimeoutSeconds != nil {
                        Stepper("超时 \(model.configuration.operationTimeoutSeconds ?? 60) 秒", value: Binding(get: { model.configuration.operationTimeoutSeconds ?? 60 }, set: { model.configuration.operationTimeoutSeconds = $0 }), in: 0...3600, step: 10)
                    }
                }
                Section {
                    TextField("筛选对象", text: $model.search)
                    DisclosureGroup("按名称批量选择") {
                        TextField("逗号、分号或换行分隔", text: $model.bulkNames, axis: .vertical).lineLimit(2...6)
                        Button("匹配并选择") { model.applyBulkNames() }
                        if !model.bulkFeedback.isEmpty { Text(model.bulkFeedback).font(.caption).foregroundStyle(.secondary) }
                    }
                    HStack {
                        Button("选择匹配对象") { for object in model.visibleObjects where model.objectEnabled(object) { model.select(object, enabled: true) } }
                        Spacer()
                        Button("取消选择") { model.configuration.objects = [] }
                    }
                    ForEach(model.visibleObjects) { object in
                        VStack(alignment: .leading) {
                            Toggle(isOn: Binding(get: { model.configuration.objects.contains { $0.id == object.id } }, set: { model.select(object, enabled: $0) })) {
                                Text(object.name)
                                Text(object.kind.title + (object.signature.isEmpty ? "" : " · " + object.signature)).font(.caption).foregroundStyle(.secondary)
                            }.disabled(!model.objectEnabled(object))
                            if object.kind == .table, model.configuration.objects.contains(where: { $0.id == object.id }) {
                                TextField("可选 WHERE 条件（不含 WHERE）", text: Binding(get: { model.configuration.tableFilters[object.name] ?? "" }, set: { model.configuration.tableFilters[object.name] = $0 }))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                } header: { Text("对象 · 已选 \(model.configuration.objects.count)") }
                footer: { Text("驱动不支持的对象不可选。Doris 仅作为来源；Redis、Elasticsearch、Kafka 不使用关系对象迁移。").font(.caption) }
            }
            .disabled(model.manager.hasActiveRuns)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationTitle("数据迁移").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    HStack {
                        ProgressView().controlSize(.small).opacity(model.isPreparing || !model.loadingSides.isEmpty ? 1 : 0)
                        Text(model.message ?? model.manager.persistenceError).font(.caption).foregroundStyle(.red).lineLimit(3)
                        Spacer(minLength: 0)
                    }.frame(height: statusHeight)
                    HStack {
                        Button("运行记录", systemImage: "clock") { history = true }
                        Spacer()
                        Button("预览传输计划", systemImage: "doc.text.magnifyingglass") { model.prepare() }
                            .buttonStyle(.borderedProminent).disabled(!model.canPrepare)
                    }
                }.padding().background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { model.invalidatePreview(); dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("交换来源与目标", systemImage: "arrow.up.arrow.down") { model.swap() }
                        .disabled(!model.loadingSides.isEmpty || model.manager.hasActiveRuns)
                }
            }
        }
        .onChange(of: model.configuration.content) { _, _ in model.pruneSelection() }
        .sheet(isPresented: $model.showingPreview) {
            if let plan = model.preview { MobileTransferPreview(model: model, plan: plan).id(plan.id) }
        }
        .sheet(isPresented: $history) { MobileTransferHistoryView(manager: model.manager) }
        .sheet(isPresented: $saved) { savedTasks }
        .sheet(item: Binding(get: { model.credentialRequest }, set: { if $0 == nil { model.cancelCredentialPrompt() } }), onDismiss: { model.presentNextCredential() }) { profile in
            NavigationStack {
                Form { Text(profile.name); SecureField("本次连接密码", text: $password) }
                    .navigationTitle("输入密码").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { model.cancelCredentialPrompt(); password = "" } }
                        ToolbarItem(placement: .confirmationAction) { Button("连接") { model.supplyPassword(password); password = "" } }
                    }
            }
        }
    }
    private func endpoint(_ side: MobileTransferModel.Side, title: String) -> some View {
        Section(title) {
            Picker("连接", selection: Binding(get: { model.endpoint(side).profileID }, set: { model.chooseProfile($0, side: side) })) {
                Text("选择连接").tag(UUID?.none)
                ForEach(model.profiles.filter { profile in profile.driver.isSQL && (side == .source || profile.driver != .doris || model.endpoint(side).profileID == profile.id) }) { profile in
                    Text(profile.name + " · " + profile.driver.title + (side == .target && profile.driver == .doris ? "（只读）" : "")).tag(Optional(profile.id))
                }
            }
            Picker("数据库", selection: Binding(get: { model.endpoint(side).database }, set: { model.chooseDatabase($0, side: side) })) {
                if (side == .source ? model.sourceDatabases : model.targetDatabases).isEmpty { Text("选择数据库").tag("") }
                if !model.endpoint(side).database.isEmpty, !(side == .source ? model.sourceDatabases : model.targetDatabases).contains(model.endpoint(side).database) {
                    Text(model.endpoint(side).database + "（待读取）").tag(model.endpoint(side).database)
                }
                ForEach(side == .source ? model.sourceDatabases : model.targetDatabases, id: \.self) { Text($0).tag($0) }
            }
            if (side == .source ? model.sourceType : model.targetType) == .postgresql {
                Picker("Schema", selection: Binding(get: { model.endpoint(side).schema }, set: { model.chooseSchema($0, side: side) })) {
                    if !model.endpoint(side).schema.isEmpty, !(side == .source ? model.sourceSchemas : model.targetSchemas).contains(model.endpoint(side).schema) {
                        Text(model.endpoint(side).schema + "（待读取）").tag(model.endpoint(side).schema)
                    }
                    ForEach(side == .source ? model.sourceSchemas : model.targetSchemas, id: \.self) { Text($0).tag($0) }
                }
            }
            Button("重新读取" + title) { model.reload(side, preserveSelection: true) }.disabled(model.loadingSides.contains(side))
        }
    }
    private var savedTasks: some View {
        MobileTransferTaskLibraryView(model: model) { task in
            if model.isDirty { discardTask = task; changingTask = true }
            else { model.loadTask(task); saved = false }
        }
        .confirmationDialog("放弃当前未保存的配置并打开任务？", isPresented: $changingTask, titleVisibility: .visible) {
            Button("打开") { model.loadTask(discardTask); saved = false }
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { model.message = error.localizedDescription } }
}

struct MobileTransferPreview: View {
    @Bindable var model: MobileTransferModel
    let plan: DataTransferPlan
    @State private var acknowledged = false
    var body: some View {
        NavigationStack {
            List {
                Section("目标与范围") {
                    LabeledContent("来源", value: model.label(plan.source)); LabeledContent("目标", value: model.label(plan.target))
                    Text(plan.configuration.strategy.title)
                    Text("\(plan.items.count) 个对象")
                }
                if !plan.warnings.isEmpty { Text(plan.warnings.joined(separator: "\n\n")).foregroundStyle(.orange) }
                if !plan.missingOwners.isEmpty { Text("缺少所有者：" + plan.missingOwners.joined(separator: ", ")).foregroundStyle(.red) }
                Section("完整计划 SQL") { Text(plan.sql).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Section {
                    Text("开始时重新校验结构。追加与 Upsert 逐表提交；覆盖在一个数据事务中执行。取消会保留已提交数据和已创建结构，重建失败会保留备份。")
                    Toggle("我已确认目标及覆盖／重建范围", isOn: $acknowledged)
                    Toggle("安全锁", isOn: Binding(get: { model.safetyLock.isEnabled }, set: { if $0 { model.safetyLock.enable() } else { model.safetyLock.disable() } }))

                }
            }
            .safeAreaInset(edge: .bottom) {
                Button("确认传输", role: .destructive) { model.startReviewedPlan() }
                    .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
                    .disabled(!acknowledged || model.safetyLock.isEnabled || model.blocksWrites || !model.allowsWrites() || plan.ownership == .preserve && !plan.missingOwners.isEmpty)
                    .accessibilityIdentifier("confirmTransfer")
                    .padding().frame(maxWidth: .infinity).background(.bar)
            }
            .navigationTitle("确认数据迁移").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回修改") { model.showingPreview = false } } }
        }
    }
}

struct MobileTransferHistoryView: View {
    @Bindable var manager: DataTransferManager
    @Environment(\.dismiss) private var dismiss
    @State private var verifying: UUID?
    var body: some View {
        NavigationStack {
            List {
                ForEach(manager.runs) { run in
                    Section {
                        Text(run.sourceLabel + " → " + run.targetLabel).font(.caption)
                        Text(run.status.title).font(.headline)
                        Text(run.message).font(.caption).textSelection(.enabled)
                        ForEach(run.items) { item in
                            LabeledContent(item.name, value: "\(item.committedRows) 行 · " + item.status.title)
                            if !item.message.isEmpty { Text(item.message).font(.caption).foregroundStyle(.secondary) }
                        }
                        if !run.backupTables.isEmpty { Text("保留备份：" + run.backupTables.joined(separator: ", ")).textSelection(.enabled) }
                        if run.status.isActive { Button("取消传输", role: .destructive) { manager.cancel(run.id) } }
                        else if [.uncertain, .interrupted].contains(run.status), run.verifiedAt == nil { Button("已核对服务器结果…") { verifying = run.id } }
                    } header: { Text(run.name) }
                }
                if !manager.persistenceError.isEmpty { Text(manager.persistenceError).foregroundStyle(.red) }
            }
            .navigationTitle("传输记录").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .confirmationDialog("确认已核对目标数据和保留结构？解除后也不会重放上次任务。", isPresented: Binding(get: { verifying != nil }, set: { if !$0 { verifying = nil } }), titleVisibility: .visible) {
                Button("已核对，结束待核实状态") { if let verifying { manager.acknowledgeOutcome(verifying) }; verifying = nil }
            }
        }
    }
}
