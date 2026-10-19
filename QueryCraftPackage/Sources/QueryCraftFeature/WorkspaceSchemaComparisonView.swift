import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceSchemaComparisonView: View {
    @Bindable var model: WorkspaceSchemaComparisonModel
    weak var window: NSWindow?
    var pasteboard: NSPasteboard = .general
    var makeSavePanel: () -> NSSavePanel = { NSSavePanel() }
    private enum Step { case setup, reading, differences, review, deployment }
    @State private var step: Step = .setup
    @State private var reviewFocusedSQL = ""
    @State private var reviewFocusedKey: ReviewKey?
    @State private var isPreparingReviewFocus = false
    private struct ReviewKey: Hashable {
        let selection: String
        let rollback: Bool
        let comparedAt: Date?
        let ignoreForeignKeys: Bool
    }
    private var reviewKey: ReviewKey { .init(selection: reviewSelection, rollback: reviewRollback, comparedAt: model.comparedAt, ignoreForeignKeys: model.ignoreForeignKeyChecks) }
    @State private var reviewRollback = false
    @State private var confirmsDeployment = false
    @State private var reviewSelection = "all"
    @State private var operationError: String?
    @State private var comparisonFailed = false
    private var copy: AppCopy { .current }

    var body: some View {
        Group {
            switch step {
            case .setup:
                SchemaComparisonSetupPage(model: model, window: window,
                                                returnsToResults: model.comparedAt != nil) { source, target, options in
                    let unchanged = model.source == source && model.target == target && model.options == options
                    model.source = source
                    model.target = target
                    model.options = options
                    if !unchanged || model.phase != .ready {
                        step = .reading
                        model.compare()
                    } else { step = .differences }
                } cancel: {
                    if model.comparedAt != nil { step = .differences }
                    else { window?.performClose(nil) }
                }
            case .reading:
                readingContent
            case .differences:
                comparisonContent
            case .review:
                reviewContent
            case .deployment:
                SchemaComparisonDeploymentView(deployment: model.deployment, target: model.endpointDescription(model.target) + " / " + model.target.database,
                    canRollback: model.canRollback, previous: { reviewRollback = false; step = .review },
                    recompare: { step = .reading; model.compare() }, reviewRollback: { reviewRollback = true; reviewSelection = "all"; step = .review },
                    exportLog: { exportSQL($0) })
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .modifier(SchemaComparisonActionBarStyle())
        .toolbar {
                ToolbarItem {
                    Button { step = .setup } label: {
                        Label(copy.text("选择数据库", "Choose Databases"), systemImage: "externaldrive.connected.to.line.below")
                    }.labelStyle(.iconOnly)
                        .disabled(step != .differences || model.phase == .loading)
                        .accessibilityIdentifier("schemaComparisonConfigure")
                }
                ToolbarItem {
                    Button { model.compare() } label: {
                        Label(copy.text("重新比较", "Compare Again"), systemImage: "arrow.clockwise")
                    }.labelStyle(.iconOnly).keyboardShortcut("r", modifiers: .command)
                        .disabled(step != .differences || !model.canCompare)
                        .accessibilityIdentifier("schemaComparisonRefresh")
                }
        }
        .confirmationDialog(reviewRollback ? copy.text("执行结构回退？", "Run Schema Rollback?") : copy.text("部署到目标数据库？", "Deploy to Target Database?"), isPresented: $confirmsDeployment, titleVisibility: .visible) {
            Button(reviewRollback ? copy.text("执行回退", "Run Rollback") : copy.text("部署", "Deploy"), role: hasDestructiveDeployment ? .destructive : nil) {
                Task {
                    do { try await model.deploy(rollback: reviewRollback); step = .deployment }
                    catch { comparisonFailed = false; operationError = error.localizedDescription }
                }
            }.accessibilityIdentifier("schemaComparisonConfirmDeploy")
            Button(copy.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(model.endpointDescription(model.target) + " / " + model.target.database + "\n" + copy.text("将执行当前审核的 SQL。MySQL DDL 会隐式提交；结构回退不能恢复已删除的数据。", "The reviewed SQL will run. MySQL DDL implicitly commits; schema rollback cannot recover deleted data."))
        }
        .task { await model.loadProfiles() }
        .onChange(of: step, initial: true) { window?.title = stepTitle }
        .onChange(of: model.phase) {
            guard step == .reading else { return }
            if model.phase == .ready { step = .differences }
            else if model.phase == .failed {
                if model.differences.isEmpty {
                    step = .setup
                    comparisonFailed = true
                    operationError = model.errorMessage
                } else { step = .differences }
            }
        }
        .alert(comparisonFailed ? copy.text("未能完成比较", "Comparison Failed") : copy.text("操作未完成", "Operation Failed"), isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) {
            if comparisonFailed {
                Button(copy.text("重新比较", "Try Again")) {
                    operationError = nil
                    step = .reading
                    model.compare()
                }
                Button(copy.text("修改连接", "Edit Connections"), role: .cancel) { operationError = nil }
            } else {
                Button(copy.text("好", "OK"), role: .cancel) { operationError = nil }
            }
        } message: { Text(operationError ?? "") }
    }

    private var stepTitle: String {
        switch step {
        case .setup: copy.text("选择数据库", "Choose Databases")
        case .reading: copy.text("读取结构", "Reading Schemas")
        case .differences: copy.text("选择差异", "Select Changes")
        case .review: copy.text("审核 SQL", "Review SQL")
        case .deployment: copy.text("执行记录", "Execution Log")
        }
    }

    private var readingContent: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(model.isCancelling ? copy.text("正在停止比较…", "Stopping comparison…") :
                        model.readingProgress.isComparing ? copy.text("正在计算结构差异", "Comparing Schemas") :
                        copy.text("正在读取数据库结构", "Reading Database Schemas")).font(.headline)
                    Spacer()
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                        .opacity(model.readingProgress.total == nil || model.readingProgress.isComparing ? 1 : 0)
                }.frame(height: 24, alignment: .leading)
                SchemaComparisonProgressIndicator(fraction: model.readingProgress.fraction)
                    .frame(height: 12)
                HStack {
                    Text(model.progress).lineLimit(1)
                    Spacer()
                    Text(model.readingProgress.fraction.map { "\(Int($0 * 100))%" } ?? "")
                }.font(.callout).monospacedDigit().foregroundStyle(.secondary).frame(height: 20)
                readingEndpoint(copy.text("源", "Source"), database: model.source.database, progress: model.readingProgress.source)
                readingEndpoint(copy.text("目标", "Target"), database: model.target.database, progress: model.readingProgress.target)
            }.frame(width: 460)
            Spacer()
            HStack {
                Spacer()
                Button(copy.text("取消", "Cancel"), action: model.cancel).disabled(model.isCancelling)
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("schemaComparisonCancel")
            }.modifier(SchemaComparisonFooterStyle())
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func readingEndpoint(_ title: String, database: String, progress: SchemaComparisonLoadProgress) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(database).lineLimit(1).truncationMode(.middle)
                Text(progress.objectName.isEmpty ? " " : progress.objectName).font(.caption)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(progress.total.map { "\(progress.completed)/\($0)" } ?? "—")
                .monospacedDigit().foregroundStyle(.secondary)
        }.frame(height: 44)
    }

    private var comparisonContent: some View {
        VStack(spacing: 0) {
            SchemaComparisonResultsView(model: model)
            Divider()
            SchemaComparisonFooter(model: model, previous: { step = .setup }, next: {
                reviewSelection = "all"
                reviewRollback = false
                step = .review
            })
        }
    }

    private var reviewGroups: [SchemaComparisonReviewGroup] { SchemaComparisonReviewGroup.groups(model.selectedDifferences) }

    private var reviewContent: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $reviewSelection) {
                    Label(copy.text("全部变更", "All Changes"), systemImage: "doc.text").tag("all")
                    Section(copy.text("已选对象（\(reviewGroups.count)）", "Selected Objects (\(reviewGroups.count))")) {
                        ForEach(reviewGroups) { group in
                            HStack(spacing: 8) {
                                Image(systemName: group.symbol).foregroundStyle(reviewColor(group.status))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title).lineLimit(1)
                                    if let kind = group.routineKind { Text(kind).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 4)
                                Text("\(group.differences.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }.tag(group.id)
                        }
                    }
                }.listStyle(.sidebar)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
                    .accessibilityIdentifier("schemaComparisonReviewObjects")
            } detail: {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.target.database).font(.headline).lineLimit(1)
                            Text(model.endpointDescription(model.target) + " · MySQL " + model.targetVersion)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        HStack(spacing: 16) {
                            reviewCount(.added, copy.text("新增", "Create"))
                            reviewCount(.modified, copy.text("修改", "Modify"))
                            reviewCount(.targetOnly, copy.text("删除", "Remove"))
                        }.font(.body.weight(.medium)).monospacedDigit().fixedSize()
                        ProgressView().controlSize(.small).frame(width: 16, height: 16).opacity(model.isPlanning ? 1 : 0)
                        if model.options.enableRollback {
                            Picker(copy.text("脚本", "Script"), selection: $reviewRollback) {
                                Text(copy.text("部署", "Forward")).tag(false)
                                Text(copy.text("回退", "Rollback")).tag(true)
                            }.pickerStyle(.segmented).frame(width: 130)
                        }
                    }.padding(.horizontal, 16).frame(height: 52)
                    Divider()
                    SchemaComparisonSQLView(ddl: reviewSQL)
                        .overlay(alignment: .topTrailing) { if isPreparingReviewFocus { ProgressView().controlSize(.small).padding(12) } }
                }.frame(minWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
            }.navigationSplitViewStyle(.balanced)
            Divider()
            HStack(spacing: 8) {
                Button(copy.text("复制 SQL", "Copy SQL"), systemImage: "doc.on.doc") { copySQL(reviewSQL) }
                    .disabled(!reviewScriptAvailable).accessibilityIdentifier("schemaComparisonCopy")
                Button(copy.text("导出 SQL…", "Export SQL…"), systemImage: "square.and.arrow.up") { exportSQL(reviewSQL) }
                    .keyboardShortcut("s", modifiers: .command).disabled(!reviewScriptAvailable)
                    .accessibilityIdentifier("schemaComparisonPreviewExport")
                Spacer()
                Button(copy.text("上一步", "Back"), systemImage: "chevron.left") { step = .differences }
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("schemaComparisonPreviewDone")
                Button(copy.text("取消", "Cancel")) { window?.performClose(nil) }
                Button(reviewRollback ? copy.text("执行回退…", "Run Rollback…") : copy.text("部署所选 \(model.selectedDifferences.count) 项…", "Deploy \(model.selectedDifferences.count) Changes…"), systemImage: "play.fill") { confirmsDeployment = true }
                    .modifier(SchemaComparisonPrimaryActionStyle())
                    .disabled(!reviewActionsEnabled || model.nativePlan == nil || (reviewRollback ? !model.canRollback : model.hasDeployedCurrentComparison))
                    .accessibilityIdentifier("schemaComparisonDeploy")
            }.modifier(SchemaComparisonFooterStyle())
        }.task(id: reviewKey) { await prepareReviewFocus() }
    }

    private func reviewColor(_ status: SchemaComparisonDifference.Status) -> Color {
        switch status { case .added: .green; case .targetOnly: .red; default: .blue }
    }
    private func reviewCount(_ status: SchemaComparisonDifference.Status, _ title: String) -> some View {
        let symbol: String = switch status {
        case .added: "plus.circle"
        case .targetOnly: "minus.circle"
        default: "arrow.left.arrow.right"
        }
        return HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(reviewColor(status))
            Text(title + " \(reviewGroups.filter { $0.status == status }.count)").foregroundStyle(.primary)
        }.accessibilityElement(children: .combine)
    }

    private var reviewSQL: String {
        if let native = model.nativeResult {
            if reviewSelection == "all" { return reviewRollback ? model.nativePlan?.rollbackSQL ?? "" : model.script }
            if native.units.contains(where: { $0.difference.id == reviewSelection || $0.difference.groupKey == reviewSelection }) {
                return reviewFocusedKey == reviewKey ? reviewFocusedSQL : ""
            }
        }
        let focused = model.selectedDifferences.filter { $0.id == reviewSelection || $0.groupKey == reviewSelection }
        return (focused.isEmpty ? model.selectedDifferences : focused).compactMap(\.sqlForReview).joined(separator: "\n\n")
    }
    private var hasDestructiveDeployment: Bool { reviewRollback || model.selectedDifferences.contains(where: \.needsDestructiveReview) }
    private var reviewScriptAvailable: Bool { !isPreparingReviewFocus && model.canExport && !reviewSQL.isEmpty }
    private var reviewActionsEnabled: Bool { reviewScriptAvailable }

    @MainActor private func prepareReviewFocus() async {
        let key = reviewKey
        guard key.selection != "all", let document = model.nativeResult else {
            isPreparingReviewFocus = false; reviewFocusedKey = nil; reviewFocusedSQL = ""; return
        }
        isPreparingReviewFocus = true; reviewFocusedKey = nil; reviewFocusedSQL = ""
        var ids = Set(model.selectedDifferences.filter { $0.id == key.selection || $0.groupKey == key.selection }.map(\.id))
        var previous: Set<String>
        repeat {
            previous = ids
            for unit in document.units where ids.contains(unit.difference.id) { ids.formUnion(unit.difference.requiredIDs) }
        } while previous != ids
        do {
            let plan = try await SchemaComparisonNativeEngine().plan(result: document, selectedIDs: ids, ignoreForeignKeyChecks: key.ignoreForeignKeys)
            try Task.checkCancellation()
            guard reviewKey == key else { return }
            reviewFocusedSQL = key.rollback ? plan.rollbackSQL : plan.sql
            reviewFocusedKey = key
        } catch { guard !Task.isCancelled, reviewKey == key else { return }; operationError = error.localizedDescription }
        if reviewKey == key { isPreparingReviewFocus = false }
    }

    private func copySQL(_ sql: String) {
        pasteboard.clearContents()
        pasteboard.setString(sql, forType: .string)
    }

    private func exportSQL(_ sql: String) {
        guard !sql.isEmpty, let window else { return }
        let panel = makeSavePanel()
        if panel.nameFieldStringValue.isEmpty { panel.nameFieldStringValue = "schema-sync.sql" }
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText]
        panel.beginSheetModal(for: window.attachedSheet ?? window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try sql.write(to: url, atomically: true, encoding: .utf8) }
            catch { comparisonFailed = false; operationError = error.localizedDescription }
        }
    }
}

/// First page of the workflow. Draft changes are committed only by Next.
private struct SchemaComparisonSetupPage: View {
    let model: WorkspaceSchemaComparisonModel
    weak var window: NSWindow?
    let returnsToResults: Bool
    var compare: (WorkspaceSchemaComparisonModel.Endpoint, WorkspaceSchemaComparisonModel.Endpoint, SchemaComparisonOptions) -> Void
    var cancel: () -> Void
    @State private var source: SchemaComparisonEndpointDraft
    @State private var target: SchemaComparisonEndpointDraft
    @State private var options: SchemaComparisonOptions
    @State private var showsOptions = false
    @State private var configurationError: String?
    @State private var showsTables = false
    @State private var tables: [String] = []
    @State private var tableSearch = ""
    @State private var loadingTables = false
    @State private var tableHasLoaded = false
    @State private var tableReload = 0
    @State private var tableError: String?
    @State private var scopeIdentity: ScopeIdentity
    private struct ScopeIdentity: Equatable {
        let profileID: UUID?
        let database: String
    }
    private struct TableRequest: Equatable {
        let endpoint: WorkspaceSchemaComparisonModel.Endpoint
        let active: Bool
        let reload: Int
    }
    private var copy: AppCopy { .current }

    init(model: WorkspaceSchemaComparisonModel, window: NSWindow?, returnsToResults: Bool = false,
         compare: @escaping (WorkspaceSchemaComparisonModel.Endpoint, WorkspaceSchemaComparisonModel.Endpoint, SchemaComparisonOptions) -> Void,
         cancel: @escaping () -> Void) {
        self.model = model
        self.window = window
        self.returnsToResults = returnsToResults
        self.compare = compare
        self.cancel = cancel
        _source = State(initialValue: model.makeEndpointDraft(model.source))
        _target = State(initialValue: model.makeEndpointDraft(model.target))
        _options = State(initialValue: model.options)
        _scopeIdentity = State(initialValue: ScopeIdentity(profileID: model.source.profileID, database: model.source.database))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 28) {
                        SchemaComparisonEndpointForm(draft: source, profiles: model.profiles, isSource: true)
                        Button { swap(&source, &target) } label: {
                            Label(copy.text("交换源和目标", "Swap Source and Target"), systemImage: "arrow.left.arrow.right")
                        }.labelStyle(.iconOnly).buttonStyle(.bordered)
                            .help(copy.text("交换源和目标", "Swap Source and Target"))
                            .accessibilityIdentifier("schemaComparisonSwap").padding(.top, 55)
                        SchemaComparisonEndpointForm(draft: target, profiles: model.profiles, isSource: false)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(copy.text("表与视图", "Tables and Views")).font(.headline)
                            Text(options.selectedTables.map { copy.text("已选 \($0.count) 张表", "\($0.count) tables selected") }
                                 ?? copy.text("比较所有表", "Compare All Tables"))
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button(showsTables ? copy.text("比较所有表", "Compare All Tables") : copy.text("指定表…", "Choose Tables…")) {
                                showsTables.toggle()
                                if !showsTables { options.selectedTables = nil }
                                else if options.selectedTables == nil { options.selectedTables = [] }
                            }.disabled(!source.canCompare).accessibilityIdentifier("schemaComparisonChooseTables")
                        }
                        if showsTables {
                            HStack {
                                TextField(copy.text("搜索表名", "Find Table"), text: $tableSearch).textFieldStyle(.roundedBorder)
                                Button(copy.text("全选", "Select All")) { options.selectedTables = tables }
                                    .disabled(loadingTables).accessibilityIdentifier("schemaComparisonSelectAllTables")
                                Button(copy.text("全不选", "Select None")) { options.selectedTables = [] }
                            }
                            SchemaComparisonTableChecklist(
                                names: tables.filter { tableSearch.isEmpty || $0.localizedStandardContains(tableSearch) },
                                selected: Set(options.selectedTables ?? []), isEnabled: !loadingTables
                            ) { name, selected in
                                var selectedNames = Set(options.selectedTables ?? [])
                                if selected { selectedNames.insert(name) } else { selectedNames.remove(name) }
                                options.selectedTables = selectedNames.sorted()
                            }.frame(height: 150)
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).opacity(loadingTables ? 1 : 0)
                                Text(tableError ?? (loadingTables ? copy.text("正在读取源数据库的表…", "Loading source tables…") :
                                    tableHasLoaded && tables.isEmpty ? copy.text("源数据库没有可见的表或视图", "No visible tables or views") : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                                if tableError != nil {
                                    Button(copy.text("重试", "Retry")) { tableReload += 1 }
                                }
                            }.frame(height: 22)
                        }
                    }
                    Divider()
                    HStack {
                        Toggle(copy.text("忽略注释差异", "Ignore Comment Differences"), isOn: $options.ignoresComments)
                            .toggleStyle(.checkbox).accessibilityIdentifier("schemaComparisonIgnoreComments")
                        Spacer()
                    }
                }.frame(maxWidth: 920).padding(32).frame(maxWidth: .infinity)
            }
            Divider()
            HStack(spacing: 10) {
                Button(copy.text("保存配置…", "Save Configuration…"), systemImage: "square.and.arrow.down", action: saveConfiguration)
                    .accessibilityIdentifier("schemaComparisonSaveConfiguration")
                Button(copy.text("载入配置…", "Load Configuration…"), systemImage: "folder", action: loadConfiguration)
                    .accessibilityIdentifier("schemaComparisonLoadConfiguration")
                Button(copy.text("选项…", "Options…"), systemImage: "slider.horizontal.3") { showsOptions = true }
                    .accessibilityIdentifier("schemaComparisonOptions")
                Spacer()
                Button(returnsToResults ? copy.text("返回差异", "Back to Changes") : copy.text("取消", "Cancel"), action: cancel)
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("schemaComparisonConnectionsCancel")
                Button(copy.text("开始比较", "Compare"), systemImage: "arrow.right") { compare(source.value, target.value, options) }
                    .modifier(SchemaComparisonPrimaryActionStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!source.canCompare || !target.canCompare || !options.hasScope || options.validationMessage != nil || model.isLoadingProfiles)
                    .accessibilityIdentifier("schemaComparisonConnectionsCompare")
            }.modifier(SchemaComparisonFooterStyle())
        }
        .frame(minWidth: 860, idealWidth: 940, maxWidth: .infinity,
               minHeight: 480, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await model.loadProfiles()
            guard !Task.isCancelled else { return }
            synchronizeProfiles()
        }
        .onChange(of: model.profiles) { synchronizeProfiles() }
        .task(id: TableRequest(endpoint: source.value, active: showsTables, reload: tableReload)) {
            let input = source.value
            let identity = ScopeIdentity(profileID: input.profileID, database: input.database)
            if identity != scopeIdentity {
                scopeIdentity = identity
                tables = []
                tableHasLoaded = false
                options.selectedTables = showsTables ? [] : nil
                tableError = nil
            }
            loadingTables = false
            guard showsTables, source.canCompare else { return }
            loadingTables = true
            tableError = nil
            do {
                try await Task.sleep(for: .milliseconds(250))
                let names = try await source.tableNames()
                try Task.checkCancellation()
                guard source.value == input else { return }
                tables = names
                tableHasLoaded = true
                loadingTables = false
            } catch is CancellationError { return }
            catch {
                guard source.value == input else { return }
                tableError = error.localizedDescription
                loadingTables = false
            }
        }
        .onDisappear { source.close(); target.close() }
        .sheet(isPresented: $showsOptions) {
            SchemaComparisonOptionsView(options: options) { options = $0; showsOptions = false } cancel: { showsOptions = false }
        }
        .alert(copy.text("配置操作失败", "Configuration Error"), isPresented: Binding(
            get: { configurationError != nil }, set: { if !$0 { configurationError = nil } }
        )) {
            Button(copy.text("好", "OK"), role: .cancel) { configurationError = nil }
        } message: { Text(configurationError ?? "") }
    }

    private func synchronizeProfiles() {
        source.selectProfile(model.profiles.first { $0.id == (source.value.profileID ?? model.source.profileID) } ?? model.profiles.first)
        target.selectProfile(model.profiles.first { $0.id == (target.value.profileID ?? model.target.profileID) } ?? model.profiles.dropFirst().first ?? model.profiles.first)
        if source.phase == .idle { source.reloadDatabases() }
        if target.phase == .idle { target.reloadDatabases() }
    }

    private func saveConfiguration() {
        guard let window else { return }
        let configuration = SchemaComparisonConfiguration(source: .init(profileID: source.value.profileID, database: source.database),
            target: .init(profileID: target.value.profileID, database: target.database), options: options)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "schema-comparison.json"
        panel.beginSheetModal(for: window.attachedSheet ?? window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(configuration).write(to: url, options: .atomic)
            } catch { configurationError = error.localizedDescription }
        }
    }

    private func loadConfiguration() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window.attachedSheet ?? window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let config = try JSONDecoder().decode(SchemaComparisonConfiguration.self, from: Data(contentsOf: url))
                guard config.formatVersion == 1 else { throw configurationFailure(copy.text("不支持此配置文件版本。", "Unsupported configuration version.")) }
                let ids = Set(model.profiles.map(\.id))
                guard [config.source.profileID, config.target.profileID].compactMap({ $0 }).allSatisfy(ids.contains) else {
                    throw configurationFailure(copy.text("配置引用的连接在本机不存在，请先添加相应连接。", "This configuration references connections not saved on this Mac."))
                }
                scopeIdentity = ScopeIdentity(profileID: config.source.profileID, database: config.source.database)
                showsTables = config.options.selectedTables != nil
                source.applyConfiguration(config.source, profile: model.profiles.first { $0.id == config.source.profileID })
                target.applyConfiguration(config.target, profile: model.profiles.first { $0.id == config.target.profileID })
                options = config.options
            } catch { configurationError = error.localizedDescription }
        }
    }

    private func configurationFailure(_ message: String) -> NSError {
        NSError(domain: "QueryCraft.SchemaComparison.Configuration", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private struct SchemaComparisonEndpointForm: View {
    @Bindable var draft: SchemaComparisonEndpointDraft
    let profiles: [ConnectionProfile]
    let isSource: Bool
    @State private var showsPassword = false
    private var copy: AppCopy { .current }
    private var prefix: String { isSource ? "schemaComparisonSource" : "schemaComparisonTarget" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isSource ? copy.text("源数据库", "Source Database") : copy.text("目标数据库", "Target Database"))
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.text("连接", "Connection")).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                        SchemaComparisonConnectionPicker(profiles: profiles, selection: draft.value.profileID,
                                                         accessibilityIdentifier: prefix) { id in
                            draft.selectProfile(profiles.first { $0.id == id })
                        }.frame(height: 25).accessibilityIdentifier(prefix)
                            .accessibilityLabel(isSource ? copy.text("源连接", "Source Connection") : copy.text("目标连接", "Target Connection"))
                        Button { showsPassword = true } label: { Image(systemName: "key") }
                            .buttonStyle(.bordered).disabled(draft.profile == nil)
                            .help(copy.text("临时密码", "Temporary Password"))
                            .accessibilityIdentifier(prefix + "Authentication")
                            .popover(isPresented: $showsPassword) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(copy.text("连接密码", "Connection Password")).font(.headline)
                                    SecureField(copy.text("使用已保存的密码，或输入临时密码", "Use saved password, or enter a temporary password"), text: $draft.password)
                                        .textFieldStyle(.roundedBorder).accessibilityIdentifier(prefix + "Password")
                                    HStack {
                                        Text(copy.text("仅用于本次比较", "For this comparison only")).font(.callout).foregroundStyle(.secondary)
                                        Spacer()
                                        Button(copy.text("读取数据库", "Load Databases")) { draft.reloadDatabases(); showsPassword = false }
                                            .keyboardShortcut(.defaultAction)
                                    }
                                }.padding(16).frame(width: 340)
                            }
                    }
                }
            if let profile = draft.profile {
                Text("MySQL · " + profile.host + ":" + String(profile.port))
                    .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(copy.text("数据库", "Database")).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                        SchemaComparisonDatabaseComboBox(text: $draft.database, databases: draft.databases,
                                                         accessibilityIdentifier: prefix + "Database")
                            .frame(height: 25).disabled(draft.profile == nil)
                            .accessibilityIdentifier(prefix + "Database")
                            .accessibilityLabel(isSource ? copy.text("源数据库", "Source Database") : copy.text("目标数据库", "Target Database"))
                        Button(action: draft.reloadDatabases) { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.bordered).disabled(draft.profile == nil || draft.phase == .loading)
                            .help(copy.text("重新读取数据库", "Reload Databases"))
                            .accessibilityIdentifier(prefix + "LoadDatabases")
                    }
                }
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).opacity(draft.phase == .loading ? 1 : 0)
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(draft.errorMessage ?? status).accessibilityIdentifier(prefix + "DatabaseStatus")
                }.frame(height: 20)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private var status: String {
        switch draft.phase {
        case .idle: return ""
        case .loading: return copy.text("正在读取数据库…", "Loading databases…")
        case .ready: return draft.databases.isEmpty ? copy.text("当前账号没有可见数据库。", "No visible databases.") : ""
        case .failed: return copy.text("读取失败，检查连接或点钥匙填写密码后重试。", "Unable to load. Check the connection or enter a password using the key button.")
        }
    }
}

/// Frequent metadata progress updates stay inside the fixed footer.
private struct SchemaComparisonFooter: View {
    @Bindable var model: WorkspaceSchemaComparisonModel
    var previous: () -> Void
    var next: () -> Void
    private var copy: AppCopy { .current }

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).opacity(model.phase == .loading || model.isLoadingProfiles ? 1 : 0)
            Text(model.phase == .loading ? model.progress : model.errorMessage ?? summary)
                .font(.callout).foregroundStyle(model.errorMessage == nil ? .secondary : .primary)
                .lineLimit(2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if model.phase == .loading {
                Button(copy.text("取消", "Cancel"), action: model.cancel).disabled(model.isCancelling)
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("schemaComparisonCancel")
            }
            if model.profiles.isEmpty, !model.isLoadingProfiles {
                Button(copy.text("重载连接", "Reload Connections")) { Task { await model.loadProfiles() } }
            }
            Button(copy.text("上一步", "Back"), systemImage: "chevron.left", action: previous).disabled(model.phase == .loading)
                .accessibilityIdentifier("schemaComparisonPrevious")
            Button(copy.text("下一步：审核 SQL", "Next: Review SQL"), systemImage: "chevron.right", action: next).disabled(!model.canExport)
                .keyboardShortcut(.defaultAction)
                .modifier(SchemaComparisonPrimaryActionStyle())
                .accessibilityIdentifier("schemaComparisonPreview")
        }.modifier(SchemaComparisonFooterStyle())
    }

    private var summary: String {
        if model.profiles.isEmpty { return copy.text("请先添加 MySQL 连接。", "Add a MySQL connection first.") }
        if model.phase == .ready {
            let changed = model.differences.filter { $0.status != .equal }
            let count = changed.count
            let tableCount = Set(changed.map(\.groupKey)).count
            let unavailable = model.differences.filter { $0.status == .unavailable }.count
            if unavailable > 0 {
                return copy.text("部分完成 · \(unavailable) 个对象无法完整比较 · 本轮仅对比",
                                 "Partial result · \(unavailable) incomplete objects · Comparison only")
            }
            return copy.text("\(tableCount) 个对象 · \(count) 项差异 · 已选 \(model.selectedDifferences.count) 项",
                             "\(tableCount) objects · \(count) changes · \(model.selectedDifferences.count) selected")
        }
        return copy.text("就绪 · 只读比较", "Ready · Read-only comparison")
    }
}

extension SchemaComparisonDifference {
    var displayName: String {
        if object == "table" { return table }
        if let objectName { return objectName }
        guard let colon = object.firstIndex(of: ":") else { return kindTitle }
        return String(object[object.index(after: colon)...])
    }

    var kindTitle: String {
        let copy = AppCopy.current
        switch object.split(separator: ":", maxSplits: 1).first {
        case "column": return copy.text("字段", "Column")
        case "index": return copy.text("索引", "Index")
        case "constraint": return copy.text("约束", "Constraint")
        case "foreignKey": return copy.text("外键", "Foreign Key")
        case "trigger": return copy.text("触发器", "Trigger")
        case "view": return copy.text("视图", "View")
        case "function": return routineType == "PROCEDURE" ? copy.text("存储过程", "Procedure") : copy.text("函数", "Function")
        case "options": return copy.text("表选项", "Table Options")
        default: return copy.text("表定义", "Table Definition")
        }
    }

    var kindSymbol: String {
        switch object.split(separator: ":", maxSplits: 1).first {
        case "column": "rectangle.split.3x1"
        case "index": "list.number"
        case "constraint", "foreignKey": "key.horizontal"
        case "view": "eye"
        case "function": routineType == "PROCEDURE" ? "terminal" : "function"
        case "trigger": "bolt"
        default: "tablecells"
        }
    }

    var statusSymbol: String {
        switch status {
        case .added: "plus.circle"
        case .modified: "circle.lefthalf.filled"
        case .targetOnly: "minus.circle"
        case .equal: "equal.circle"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    var statusColor: Color {
        switch status {
        case .added: .green
        case .modified: .blue
        case .unavailable: .orange
        case .targetOnly: .red
        case .equal: .secondary
        }
    }
}

/// Uses the same system rounded-rectangle controls as the table-data footer.
struct SchemaComparisonPrimaryActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent).buttonBorderShape(.roundedRectangle).controlSize(.regular)
    }
}

struct SchemaComparisonActionBarStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.bordered).buttonBorderShape(.roundedRectangle).controlSize(.regular)
    }
}

struct SchemaComparisonFooterStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: WorkspaceDataActionControlMetrics.height + 20)
            .background(Color(nsColor: .windowBackgroundColor))
            .modifier(SchemaComparisonActionBarStyle())
    }
}
