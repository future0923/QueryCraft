import AppKit
import SwiftUI

struct DataTransferWorkbenchView: View {
    @Bindable var model: DataTransferWorkbenchModel
    @State private var showBulk = false
    @State private var folderName = ""
    @State private var folderParent: UUID?
    @State private var showingFolder = false
    @State private var showingSave = false
    @State private var taskNameDraft = ""
    @State private var taskFolderDraft: UUID?
    @State private var showingTasks: Bool

    init(model: DataTransferWorkbenchModel) {
        self.model = model
        _showingTasks = State(initialValue: !model.library.library.tasks.isEmpty || !model.library.library.folders.isEmpty)
    }

    private func copy(_ zh: String, _ en: String) -> String { AppCopy.current.text(zh, en) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TransferTaskLibraryButton(title: copy("已存任务", "Saved tasks")) {
                    if model.showingHistory { model.showingHistory = false; showingTasks = true }
                    else { showingTasks.toggle() }
                }.fixedSize()
                    .focusEffectDisabled()
                    .accessibilityLabel(copy("显示或隐藏已存任务", "Show or hide saved tasks"))
                    .help(copy("已存任务", "Saved tasks"))
                Divider().frame(height: 16)
                Text(model.taskName).font(.headline).lineLimit(1)
                if model.isDirty {
                    Text(copy("未保存", "Unsaved")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(copy("页面", "Page"), selection: $model.showingHistory) {
                    Text(copy("配置", "Configuration")).tag(false)
                    Text(copy("任务进度", "Progress")).tag(true)
                }.labelsHidden().pickerStyle(.segmented).frame(width: 172)
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }
                    .help(copy("刷新源和目标", "Refresh source and target"))
                    .disabled(!model.loadingSides.isEmpty || model.isPreparing)
                    .accessibilityLabel(copy("刷新", "Refresh"))
                    .buttonStyle(.borderless)
            }.padding(.horizontal, 16).frame(height: 46)
            Divider()
            if model.showingHistory {
                DataTransferHistoryView(manager: model.manager)
            } else {
                HStack(spacing: 0) {
                    if showingTasks {
                        DataTransferTaskTree(model: model, newFolder: { parent in folderParent = parent; folderName = ""; showingFolder = true })
                            .frame(width: 208)
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        connections
                        HStack(spacing: 0) {
                            objects
                            Divider()
                            options
                        }
                        .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 7))
                        .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.separator.opacity(0.6)) }
                        .clipShape(.rect(cornerRadius: 7))
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .controlBackgroundColor))
                }
            }
            Divider()
            if model.showingHistory { statusArea.frame(height: 40).padding(.horizontal, 16) }
            else { footer }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 900, minHeight: 620)
        .task { await model.loadProfiles() }
        .onChange(of: model.configuration.content) { model.pruneSelection() }
        .onChange(of: model.configuration.target.profileID) { model.pruneSelection() }
        .onChange(of: model.configuration) { model.invalidatePreview() }
        .onChange(of: model.library.library) { model.libraryDidChange() }
        .onReceive(NotificationCenter.default.publisher(for: .dataTransferDidFinish)) { _ in model.refresh() }
        .sheet(isPresented: $model.showingPreview) {
            if let plan = model.preview { DataTransferPreviewView(model: model, plan: plan) }
        }
        .sheet(isPresented: $showingSave) {
            VStack(alignment: .leading, spacing: 18) {
                Text(copy("保存传输任务", "Save transfer task")).font(.title3).bold()
                Text(copy("保存配置，下次可从“已存任务”打开。", "Save this configuration to reuse it from Saved tasks."))
                    .font(.callout).foregroundStyle(.secondary)
                taskOptions
                HStack {
                    Spacer()
                    Button(copy("取消", "Cancel")) { showingSave = false }.keyboardShortcut(.cancelAction)
                    Button(copy("保存", "Save")) {
                        model.taskName = taskNameDraft
                        model.taskFolderID = taskFolderDraft
                        model.save()
                        if !model.isDirty { showingSave = false }
                    }.keyboardShortcut(.defaultAction)
                        .disabled(taskNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 420)
        }
        .sheet(item: $model.filterObject) { object in
            VStack(alignment: .leading, spacing: 12) {
                Text(copy("数据过滤：", "Data filter: ") + object.name).font(.headline)
                Text(copy("输入 WHERE 条件或完整 SELECT。SELECT 必须返回全部可写字段并保留原字段名；留空传输全表。", "Enter a WHERE predicate or full SELECT. SELECT must return all writable columns with original names. Leave blank for the full table."))
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $model.filterDraft).font(.system(.body, design: .monospaced)).border(.separator).frame(minHeight: 180)
                Text("id <= 90000\nSELECT * FROM orders WHERE created_at >= '2026-01-01'").font(.caption.monospaced()).foregroundStyle(.secondary)
                HStack {
                    Button(copy("清空", "Clear")) { model.filterDraft = "" }
                    Spacer()
                    Button(copy("取消", "Cancel")) { model.filterObject = nil }.keyboardShortcut(.cancelAction)
                    Button(copy("保存", "Save")) {
                        do {
                            try TransferSQL.validateFilter(model.filterDraft)
                            model.configuration.tableFilters[object.name] = model.filterDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            model.filterObject = nil; model.invalidatePreview()
                        } catch { model.errorMessage = error.localizedDescription }
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(20).frame(width: 620)
        }
        .alert(copy("放弃未保存的配置？", "Discard unsaved configuration?"), isPresented: $model.showingDiscard) {
            Button(copy("取消", "Cancel"), role: .cancel) {}
            Button(copy("放弃并切换", "Discard and switch"), role: .destructive) { model.discardAndSwitch() }
        } message: { Text(copy("当前配置尚未保存，切换任务会丢失修改。", "The current configuration has unsaved changes.")) }
        .alert(copy("新建任务文件夹", "New task folder"), isPresented: $showingFolder) {
            TextField(copy("名称", "Name"), text: $folderName)
            Button(copy("取消", "Cancel"), role: .cancel) {}
            Button(copy("创建", "Create")) {
                do { try model.library.update { $0.folders.append(.init(name: folderName.trimmingCharacters(in: .whitespacesAndNewlines), parentID: folderParent)) } }
                catch { model.errorMessage = error.localizedDescription }
            }
        }
    }

    private var connections: some View {
        VStack(spacing: 9) {
            HStack {
                Text(copy("连接与位置", "Connections")).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: model.swap) {
                    Label(copy("交换来源与目标", "Swap source and target"), systemImage: "arrow.up.arrow.down")
                }.buttonStyle(.borderless).font(.caption)
                    .disabled(!model.loadingSides.isEmpty)
            }.frame(height: 20)
            DataTransferEndpointView(model: model, side: .source)
            DataTransferEndpointView(model: model, side: .target)
        }
    }

    private var objects: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(copy("搜索对象", "Search objects"), text: $model.objectSearch)
                        .textFieldStyle(.plain)
                }.padding(.horizontal, 8).frame(maxWidth: .infinity).frame(height: 25)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 5))
                Menu {
                    Button(copy("全选", "Select all")) { model.selectVisible(true) }
                    Button(copy("取消全选", "Deselect all")) { model.selectVisible(false) }
                    Divider()
                    Button(copy("批量录入…", "Bulk select…")) { showBulk = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(copy("对象选择操作", "Object selection actions"))
                    .accessibilityLabel(copy("对象选择操作", "Object selection actions"))
                    .popover(isPresented: $showBulk) { bulkSelection.padding(16).frame(width: 390) }
            }.frame(height: 42)
            Divider()
            List {
                ForEach(TransferObjectKind.allCases) { kind in
                    let items = model.filteredObjects.filter { $0.kind == kind }
                    if !items.isEmpty {
                        Group {
                            HStack {
                                Text(kind.title)
                                Text("\(items.count)").foregroundStyle(.secondary)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .listRowSeparator(.hidden)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(items) { object in
                                HStack(spacing: 8) {
                                    Toggle(isOn: Binding(get: { model.configuration.objects.contains { $0.id == object.id } }, set: { model.select(object, enabled: $0) })) {
                                        HStack(spacing: 6) {
                                            Text(object.name).lineLimit(1)
                                            if let table = object.parentTable { Text(table).font(.caption).foregroundStyle(.secondary) }
                                            if kind == .function || kind == .procedure { Text("(" + object.signature + ")").font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.toggleStyle(.checkbox).disabled(!model.objectEnabled(object))
                                    if kind == .table && model.configuration.content != .structureOnly && model.configuration.objects.contains(where: { $0.id == object.id }) {
                                        Button {
                                            model.filterDraft = model.configuration.tableFilters[object.name] ?? ""
                                            model.filterObject = object
                                        } label: {
                                            Label(copy(model.configuration.tableFilters[object.name, default: ""].isEmpty ? "过滤" : "已过滤", model.configuration.tableFilters[object.name, default: ""].isEmpty ? "Filter" : "Filtered"), systemImage: "line.3.horizontal.decrease")
                                                .font(.caption)
                                        }.buttonStyle(.borderless)
                                            .help(model.configuration.tableFilters[object.name] ?? copy("设置逐表 WHERE 或 SELECT 过滤", "Set a per-table WHERE or SELECT filter"))
                                    }
                                    if !model.objectEnabled(object) {
                                        Image(systemName: "info.circle").foregroundStyle(.tertiary)
                                            .help(copy("当前模式或驱动组合不支持", "Unavailable for this mode or driver pair"))
                                    }
                                }.padding(.vertical, 3)
                                    .listRowSeparator(.hidden)
                            }
                        }
                    }
                }
            }.listStyle(.inset).scrollContentBackground(.hidden)
                .overlay { objectGuidance }
            HStack {
                Text(copy("已选择 \(model.configuration.objects.count) 个对象", "\(model.configuration.objects.count) objects selected"))
                Spacer()
                if model.loadingSides.contains(.source) { ProgressView().controlSize(.mini) }
                else if model.sourceLoaded { Text(copy("共 \(model.objects.count) 个对象", "\(model.objects.count) total")) }
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4).frame(height: 28)
                .opacity(model.configuration.source.profileID == nil ? 0 : 1)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 160, maxHeight: .infinity)
        .accessibilityElement(children: .contain).accessibilityIdentifier("transfer.objects")
    }

    @ViewBuilder private var objectGuidance: some View {
        if model.configuration.source.profileID == nil {
            Text(copy("选择来源连接后，在这里勾选传输对象", "Choose a source connection to select objects here"))
                .font(.callout).foregroundStyle(Color.primary.opacity(0.78)).multilineTextAlignment(.center)
                .padding(.horizontal, 20).allowsHitTesting(false)
        } else if model.sourceLoaded && !model.loadingSides.contains(.source) && model.filteredObjects.isEmpty {
            Text(model.objects.isEmpty ? copy("当前 Schema 没有可传输对象", "No transferable objects in this schema") : copy("没有匹配的对象", "No matching objects"))
                .font(.callout).foregroundStyle(.secondary).allowsHitTesting(false)
        }
    }

    private var bulkSelection: some View {
        GroupBox(copy("批量选择对象", "Bulk object selection")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(copy("粘贴对象名称，以换行、逗号或分号分隔；支持当前库／Schema 前缀。", "Paste names separated by newlines, commas or semicolons; current database/schema prefixes are accepted."))
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $model.bulkNames).font(.system(.body, design: .monospaced)).frame(height: 80)
                HStack {
                    Text(model.bulkFeedback).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button(copy("匹配并勾选", "Match and select"), action: model.applyBulkNames)
                }
            }.padding(6)
        }
    }
    private var options: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(copy("传输配置", "Transfer options")).font(.system(size: 12, weight: .semibold))
                    .frame(height: 18)
                optionField(copy("传输内容", "Content")) {
                    TransferOptionPicker(title: copy("传输内容", "Content"), identifier: "transfer.content", selection: model.configuration.content.rawValue,
                                         items: TransferContent.allCases.map { .init(id: $0.rawValue, title: $0.title) }) {
                        if let value = TransferContent(rawValue: $0) { model.configuration.content = value }
                    }.frame(height: 28)
                }
                optionField(copy("目标处理", "Target strategy")) {
                    TransferOptionPicker(title: copy("目标处理", "Target strategy"), identifier: "transfer.strategy", selection: model.configuration.strategy.rawValue,
                                         items: TransferStrategy.allCases.map { .init(id: $0.rawValue, title: strategyLabel($0), isEnabled: strategyEnabled($0)) }) {
                        if let value = TransferStrategy(rawValue: $0) { model.configuration.strategy = value }
                    }.frame(height: 28)
                    Text(strategyExplanation).font(.caption).foregroundStyle(Color.primary.opacity(0.78))
                        .fixedSize(horizontal: false, vertical: true)
                }
                optionField(copy("目标表名", "Target table names")) {
                    TransferOptionPicker(title: copy("目标表名", "Target table names"), identifier: "transfer.nameCase", selection: model.configuration.nameCase.rawValue,
                                         items: TransferNameCase.allCases.map { .init(id: $0.rawValue, title: $0.title) }) {
                        if let value = TransferNameCase(rawValue: $0) { model.configuration.nameCase = value }
                    }.frame(height: 28)
                }
                Divider()
                executionOptions
            }.controlSize(.regular).padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 220).frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.4))
        .accessibilityElement(children: .contain).accessibilityIdentifier("transfer.options")
    }

    private func strategyLabel(_ strategy: TransferStrategy) -> String {
        switch strategy {
        case .append: copy("追加", "Append")
        case .overwrite: copy("覆盖", "Overwrite")
        case .upsert: copy("更新或插入", "Upsert")
        case .rebuild: copy("重建", "Rebuild")
        }
    }

    private var strategyExplanation: String {
        switch model.configuration.strategy {
        case .append:
            model.configuration.content == .structureOnly
                ? copy("保留已存在的对象。", "Keep existing objects.")
                : copy("保留原有数据，追加来源数据。", "Keep existing data and append source rows.")
        case .overwrite:
            model.configuration.content == .structureOnly
                ? copy("替换同名的非表对象。", "Replace non-table objects with matching names.")
                : copy("清空所选表的数据后再写入。", "Clear selected tables before copying rows.")
        case .upsert: copy("按目标主键更新或插入数据。", "Update or insert rows using the target primary key.")
        case .rebuild: copy("重新创建目标对象，成功后清理原表备份。", "Recreate target objects; remove original table backups on success.")
        }
    }

    private func optionField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func strategyEnabled(_ strategy: TransferStrategy) -> Bool {
        switch strategy {
        case .append: true
        case .rebuild: model.configuration.content != .dataOnly
        case .upsert: model.configuration.content != .structureOnly
        case .overwrite:
            model.configuration.content != .structureOnly || (model.sourceType == .mysql && model.targetType == .mysql && model.configuration.objects.contains { $0.kind != .table })
        }
    }

    private var executionOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(copy("每批行数", "Batch size")).font(.caption)
                Spacer()
                TextField("1000", value: $model.configuration.batchSize, format: .number.grouping(.never))
                    .textFieldStyle(.roundedBorder).frame(width: 72)
                    .accessibilityLabel(copy("每批行数", "Batch size"))
                    .accessibilityIdentifier("transfer.batchSize")
            }.frame(height: 28)
            HStack(spacing: 5) {
                Toggle(copy("操作超时", "Timeout"), isOn: Binding(get: { model.configuration.operationTimeoutSeconds != nil }, set: { model.configuration.operationTimeoutSeconds = $0 ? 600 : nil }))
                    .toggleStyle(.checkbox).font(.caption).fixedSize()
                    .accessibilityIdentifier("transfer.customTimeout")
                Spacer(minLength: 0)
                if model.configuration.operationTimeoutSeconds != nil {
                    TextField("600", value: Binding(get: { model.configuration.operationTimeoutSeconds ?? 600 }, set: { model.configuration.operationTimeoutSeconds = $0 }), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 54)
                        .accessibilityLabel(copy("超时秒数", "Timeout seconds"))
                    Text(copy("秒", "sec")).font(.caption)
                } else {
                    Text(copy("默认", "Default")).font(.caption).foregroundStyle(Color.primary.opacity(0.78))
                }
            }.frame(height: 28)
            Text(copy("0 秒不限时；未勾选时使用驱动默认值。", "0 = unlimited. Unchecked uses driver defaults."))
                .font(.caption).foregroundStyle(Color.primary.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
                .help(copy("超时作用于数据库操作。PostgreSQL 使用 statement_timeout，MySQL 使用查询执行和锁等待超时；网络中断可能延迟取消。", "Timeout applies to database operations. PostgreSQL uses statement_timeout; MySQL uses query and lock-wait timeouts. Network interruption may delay cancellation."))
            if model.sourceType == .postgresql && model.targetType == .postgresql {
                optionField(copy("PostgreSQL 所有者", "PostgreSQL ownership")) {
                    Picker(copy("所有者", "Ownership"), selection: $model.ownership) {
                        ForEach(TransferOwnership.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden()
                }.padding(.top, 4)
            }
        }
    }

    private var taskOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            optionField(copy("任务名称", "Task name")) {
                TextField(copy("任务名称", "Task name"), text: $taskNameDraft).textFieldStyle(.roundedBorder)
            }
            optionField(copy("文件夹", "Folder")) {
                Picker(copy("文件夹", "Folder"), selection: $taskFolderDraft) {
                    Text(copy("未分组", "Unfiled")).tag(nil as UUID?)
                    ForEach(model.library.library.folders) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden()
            }
            if !model.errorMessage.isEmpty { Text(model.errorMessage).font(.caption).foregroundStyle(.red) }
        }
    }

    private var statusArea: some View {
        HStack(spacing: 6) {
            if !model.errorMessage.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(model.errorMessage).lineLimit(1).help(model.errorMessage)
                Button(copy("重试", "Retry"), action: model.refresh).buttonStyle(.borderless)
                Button { model.errorMessage = "" } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            } else if !model.statusMessage.isEmpty {
                Text(model.statusMessage).lineLimit(1).help(model.statusMessage)
            }
        }.font(.caption).foregroundStyle(.secondary)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            statusArea.frame(maxWidth: .infinity, alignment: .leading)
            if model.isPreparing {
                ProgressView().controlSize(.small)
                Button(copy("取消准备", "Cancel preparation"), action: model.cancelPreparation)
            }
            Button(copy("保存任务…", "Save task…")) {
                taskNameDraft = model.taskName
                taskFolderDraft = model.taskFolderID
                showingSave = true
            }
            Button(copy("预览并传输…", "Preview and transfer…"), action: model.prepare)
                .buttonStyle(.borderedProminent).disabled(!model.canPrepare)
                .accessibilityIdentifier("transfer.preview")
        }.controlSize(.regular).padding(.horizontal, 16).frame(height: 56)
    }

}

private struct TransferTaskLibraryButton: NSViewRepresentable {
    let title: String
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.click))
        button.setButtonType(.momentaryPushIn)
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        button.image?.size = .init(width: 15, height: 15)
        button.imagePosition = .imageLeading
        button.identifier = .init("transfer.savedTasks")
        button.setAccessibilityIdentifier("transfer.savedTasks")
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = title
        button.setAccessibilityLabel(title)
    }
    @MainActor final class Coordinator: NSObject {
        var parent: TransferTaskLibraryButton
        init(_ parent: TransferTaskLibraryButton) { self.parent = parent }
        @objc func click() { parent.action() }
    }
}

private struct TransferPickerItem: Identifiable {
    let id: String
    let title: String
    var isEnabled = true
}

private struct TransferOptionPicker: NSViewRepresentable {
    let title: String
    let identifier: String
    let selection: String
    let items: [TransferPickerItem]
    let action: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.autoenablesItems = false
        button.controlSize = .regular
        button.font = .systemFont(ofSize: NSFont.systemFontSize)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.identifier = .init(identifier)
        button.setAccessibilityIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.isEnabled = context.environment.isEnabled
        if button.itemTitles != items.map(\.title) {
            button.removeAllItems()
            button.addItems(withTitles: items.map(\.title))
        }
        for (index, item) in items.enumerated() { button.item(at: index)?.isEnabled = item.isEnabled }
        button.selectItem(at: items.firstIndex { $0.id == selection } ?? -1)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> NSSize? {
        .init(width: proposal.width ?? 188, height: 28)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: TransferOptionPicker
        init(_ parent: TransferOptionPicker) { self.parent = parent }
        @objc func choose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard parent.items.indices.contains(index), parent.items[index].isEnabled else { return }
            parent.action(parent.items[index].id)
        }
    }
}

private struct TransferSearchPicker: View {
    let title: String
    let selection: String
    let items: [TransferPickerItem]
    let action: (String) -> Void
    @State private var showing = false
    @State private var search = ""
    @State private var highlighted: String?
    @State private var focusRequest = 0
    private var selectedTitle: String? { items.first { $0.id == selection }?.title }
    private var matches: [TransferPickerItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }

    var body: some View {
        Button {
            search = ""
            highlighted = items.contains { $0.id == selection } ? selection : items.first?.id
            focusRequest &+= 1
            showing = true
        } label: {
            HStack(spacing: 6) {
                Text(selectedTitle ?? title).foregroundStyle(selectedTitle == nil ? .secondary : .primary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 9).frame(height: 27).contentShape(.rect)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 5))
                .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(.separator.opacity(0.45)) }
        }.buttonStyle(.plain).focusEffectDisabled()
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                WorkspaceSearchPickerContent(
                    query: $search, highlightedOption: $highlighted, focusRequest: focusRequest,
                    placeholder: AppCopy.current.text("搜索", "Search"),
                    accessibilityIdentifier: "transfer.locationSearch",
                    submit: { if let highlighted { choose(highlighted) } },
                    cancel: { showing = false },
                    moveUp: { moveHighlight(-1) }, moveDown: { moveHighlight(1) }
                ) {
                    ForEach(matches) { item in
                        Button { choose(item.id) } label: {
                            HStack {
                                Image(systemName: "checkmark").opacity(item.id == selection ? 1 : 0).accessibilityHidden(true)
                                Text(item.title).lineLimit(1).truncationMode(.tail)
                                Spacer()
                            }.contentShape(.rect)
                        }.buttonStyle(.plain).tag(item.id).id(item.id)
                            .listRowSeparator(.hidden).help(item.title)
                            .accessibilityAddTraits(item.id == selection ? .isSelected : [])
                    }
                    if matches.isEmpty {
                        Text(AppCopy.current.text("没有匹配的项目", "No matching items"))
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
                            .listRowSeparator(.hidden)
                    }
                }.frame(width: 300, height: 320)
                    .onChange(of: search) { synchronizeHighlight() }
                    .onChange(of: items.map(\.id)) { synchronizeHighlight() }
            }
            .accessibilityLabel(title).accessibilityValue(selectedTitle ?? title).help(selectedTitle ?? title)
    }

    private func choose(_ id: String) {
        guard items.contains(where: { $0.id == id }) else { return }
        showing = false
        action(id)
    }
    private func synchronizeHighlight() {
        if !matches.contains(where: { $0.id == highlighted }) { highlighted = matches.first?.id }
    }
    private func moveHighlight(_ offset: Int) {
        let items = matches
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == highlighted }
        let next = current.map { $0 + offset } ?? (offset < 0 ? items.count - 1 : 0)
        highlighted = items[min(max(next, 0), items.count - 1)].id
    }
}

private struct DataTransferEndpointView: View {
    @Bindable var model: DataTransferWorkbenchModel
    let side: DataTransferWorkbenchModel.Side
    private var endpoint: TransferEndpoint { model.endpoint(side) }
    private var loading: Bool { model.loadingSides.contains(side) }
    var body: some View {
        HStack(spacing: 12) {
            Text(AppCopy.current.text(side == .source ? "来源" : "目标", side == .source ? "Source" : "Target"))
                .font(.callout).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
            TransferSearchPicker(title: AppCopy.current.text("选择连接", "Choose connection"), selection: endpoint.profileID?.uuidString ?? "", items: model.profiles.filter { side == .source ? TransferCapabilities.canRead($0.databaseType) : TransferCapabilities.canWrite($0.databaseType) }.map { .init(id: $0.id.uuidString, title: "\($0.name) · \($0.databaseType.title)") }) { model.chooseProfile(UUID(uuidString: $0), side: side) }
                .frame(maxWidth: .infinity)
            HStack(spacing: 8) {
                TransferSearchPicker(title: AppCopy.current.text("选择数据库", "Choose database"), selection: endpoint.database,
                                     items: (side == .source ? model.sourceDatabases : model.targetDatabases).map { .init(id: $0, title: $0) }) { model.chooseDatabase($0, side: side) }.disabled(loading || endpoint.profileID == nil)
                let schemas = side == .source ? model.sourceSchemas : model.targetSchemas
                if side == .source ? model.sourceType == .postgresql : model.targetType == .postgresql {
                    TransferSearchPicker(title: "Schema", selection: endpoint.schema, items: schemas.map { .init(id: $0, title: $0) }) { model.chooseSchema($0, side: side) }.disabled(loading)
                }
            }.frame(maxWidth: .infinity)
            ProgressView().controlSize(.mini).opacity(loading ? 1 : 0).frame(width: 12, height: 12)
        }.frame(height: 30)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(side == .source ? "transfer.source" : "transfer.target")
    }

}

private struct DataTransferPreviewView: View {
    @Bindable var model: DataTransferWorkbenchModel
    let plan: DataTransferPlan
    @State private var acknowledged = false
    private var blocked: Bool { plan.ownership == .preserve && !plan.missingOwners.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppCopy.current.text("确认数据传输", "Review data transfer")).font(.title2).bold()
            Text("\(location(plan.source)) → \(location(plan.target)) · \(plan.items.count) · \(plan.configuration.strategy.title)")
                .font(.callout).textSelection(.enabled)
            if blocked {
                Text(AppCopy.current.text("目标缺少所有者：", "Missing target owners: ") + plan.missingOwners.joined(separator: ", ")).foregroundStyle(.red)
                Text(AppCopy.current.text("返回后选择“跳过所有者”或“缺失所有者使用目标当前用户”，再重新预览。", "Go back, choose skip ownership or assign missing owners to the target user, then preview again."))
            }
            if !plan.warnings.isEmpty {
                ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) } } }.frame(maxHeight: 100)
            }
            WorkspaceExecutedSQLWindowView(sql: plan.sql, highlightContext: .init(databaseType: plan.target.type)).frame(minHeight: 250)
            Text(AppCopy.current.text("开始时会重新校验元数据；变化后需重新预览。追加／Upsert 逐表提交；覆盖在一个数据事务内执行。取消保留已提交数据和已创建结构。重建失败保留备份。", "Metadata is revalidated at start; changes require a new preview. Append/Upsert commit per table; overwrite uses one data transaction. Cancellation retains committed data and created structures. Failed rebuilds retain backups."))
                .font(.caption).foregroundStyle(.secondary)
            if [.overwrite, .rebuild].contains(plan.configuration.strategy) {
                Toggle(AppCopy.current.text("我已确认目标及覆盖／重建范围", "I reviewed the target and overwrite/rebuild scope"), isOn: $acknowledged).toggleStyle(.checkbox)
            }
            if !model.errorMessage.isEmpty { Text(model.errorMessage).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button(AppCopy.current.text("返回修改", "Back")) { model.showingPreview = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(AppCopy.current.text("确认传输", "Confirm transfer"), action: model.startReviewedPlan)
                    .buttonStyle(.borderedProminent)
                    .disabled(blocked || [.overwrite, .rebuild].contains(plan.configuration.strategy) && !acknowledged)
            }
        }.padding(20).frame(minWidth: 780, idealWidth: 900, minHeight: 650, idealHeight: 740)
    }

    private func location(_ connection: TransferConnection) -> String {
        [connection.endpoint.database, connection.type == .postgresql ? connection.endpoint.schema : ""]
            .filter { !$0.isEmpty }.joined(separator: ".")
    }
}
