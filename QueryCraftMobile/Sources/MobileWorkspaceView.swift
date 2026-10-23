import SwiftUI

struct MobileWorkspaceView: View {
    @Bindable var model: MobileQueryModel
    let widthKey: String
    var browser: MobileBrowserModel? = nil
    var history: [MobileQueryHistoryItem] = []
    var restoreHistory: ((MobileQueryHistoryItem) -> Void)?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var editorFocused = false
    @State private var editorSchema = MobileSQLSchemaCatalog()
    @State private var ranEditorProbe = false
    @State private var findingResults = false
    @State private var snippets = SQLSnippetStore.shared
    @State private var snippetContext = MobileSQLSnippetContext()
    @State private var showingSnippets = false
    @State private var formatting = MobileSQLFormattingContext()
    var body: some View {
        VStack(spacing: 0) {
            if !findingResults { VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let browser {
                        Menu {
                            Picker("数据库", selection: Binding(get: { model.database }, set: {
                                model.database = $0
                                if model.database == $0 { browser.selectDatabase($0) }
                            })) {
                                ForEach(browser.databases ?? [], id: \.self) { Text($0).tag($0) }
                            }
                        } label: {
                            Label(model.database.isEmpty ? "选择数据库" : model.database, systemImage: "cylinder")
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                        }.disabled(browser.databases == nil)
                    } else {
                        Label(model.database.isEmpty ? "未选择数据库" : model.database, systemImage: "cylinder")
                            .font(.subheadline.weight(.medium)).lineLimit(1)
                    }
                    Spacer()
                    Menu {
                        Toggle("安全锁", isOn: Binding(get: { model.safetyLock.isEnabled }, set: {
                            if $0 { model.safetyLock.enable() } else { model.safetyLock.disable() }
                        }))
                        Text(model.transactionTitle)
                        Button("开始事务") { model.transaction(.begin) }.disabled(model.isLoading || model.transactionState == .inTransaction || model.writeOutcomeUncertain)
                        Button("提交事务") { model.transaction(.commit) }.disabled(model.isLoading || model.transactionState != .inTransaction || model.writeOutcomeUncertain)
                        Button("回滚事务") { model.transaction(.rollback) }.disabled(model.isLoading || model.transactionState != .inTransaction || model.writeOutcomeUncertain)
                        Button("断开 SQL 会话") { model.disconnectSQL() }.disabled(model.isLoading)
                        Button("清空查询结果缓存") { model.clearQueryResults() }.disabled(model.isLoading || model.isLoadingEditing || model.hasSubmittingChanges)
                        if model.writeOutcomeUncertain { Button("已核对服务器结果，解除待核实状态") { model.acknowledgeUncertainOutcome() } }
                    } label: {
                        Label(model.transactionState == .inTransaction || model.writeOutcomeUncertain ? model.transactionTitle : (model.safetyLock.isEnabled ? "只读 SQL" : "允许写 SQL"),
                              systemImage: model.safetyLock.isEnabled ? "lock" : "lock.open")
                            .font(.caption).foregroundStyle(model.transactionState == .inTransaction ? .orange : .secondary).lineLimit(1)
                    }.accessibilityIdentifier("sqlSessionControls")
                }.padding(.horizontal, 4)
                VStack(spacing: 0) {
                    HStack {
                        Text("SQL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ProgressView().controlSize(.mini).frame(width: 16, height: 16)
                            .opacity(editorSchema.isLoading ? 1 : 0).accessibilityHidden(!editorSchema.isLoading)
                        if let message = editorSchema.errorMessage {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                .accessibilityLabel("补全元数据暂不可用：" + message)
                        }
                        Spacer()
                        Menu {
                            Button("格式化选区或当前语句") { formatting.format(.selectionOrCurrentStatement) }
                            Button("格式化整个文稿") { formatting.format(.document) }
                        } label: {
                            Image(systemName: "text.alignleft").frame(width: 32, height: 44).contentShape(.rect)
                        }.accessibilityLabel("格式化 SQL").accessibilityIdentifier("sqlFormatting")
                            .disabled(formatting.isFormatting)
                        MobileSQLSnippetControls(context: snippetContext)
                        Button { editorFocused = false; showingSnippets = true } label: { Image(systemName: "curlybraces").frame(width: 32, height: 44).contentShape(.rect) }
                            .accessibilityLabel("代码片段").accessibilityIdentifier("sqlSnippets")
                        if editorFocused {
                            Button { editorFocused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                                .accessibilityLabel("收起键盘")
                        }
                        if sizeClass == .regular { Text("⌘ Return 执行").font(.caption2).foregroundStyle(.tertiary) }
                    }.frame(height: 44).padding(.horizontal, 14).padding(.top, 12)
                    MobileSQLEditor(text: $model.sql, selection: Binding(get: { model.executionInput.selection }, set: { model.executionInput.selection = $0 }), isFocused: $editorFocused,
                                    schema: editorSchema, defaultDatabase: model.database, executionInput: model.executionInput,
                                    snippets: snippets.completionSources, snippetContext: snippetContext, formattingContext: formatting, executeAll: { model.executeAll() }) { model.execute() }
                        .frame(height: verticalSizeClass == .compact ? 60 : 130).padding(.horizontal, 8).padding(.bottom, 8)
                        .accessibilityLabel("SQL 编辑器").accessibilityIdentifier("sqlEditor")
                }.background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 14))
            }.padding(.horizontal, 12).padding(.top, 8)
            if verticalSizeClass != .compact { HStack(alignment: .firstTextBaseline) {
                if model.statementResults.count > 1 {
                    Menu { resultChoices } label: {
                        Label(model.statementResults.first(where: { $0.id == model.selectedResultID })?.title ?? "查询结果", systemImage: "chevron.down")
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                    }.disabled(model.isLoading || model.isLoadingEditing).accessibilityIdentifier("queryResultSelector")
                } else { Text("查询结果").font(.subheadline.weight(.semibold)) }
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(.horizontal, 18).frame(height: 48) } }
            MobileResultsView(data: model.displayData, revision: model.resultRevision.uuidString + (model.editing?.revision.uuidString ?? ""),
                widthKey: widthKey + ".query", hasLoaded: model.result != nil,
                isLoading: model.isLoading || model.isLoadingEditing, errorMessage: model.errorMessage,
                status: model.requiresResultReload || model.result == nil ? (model.editingMessage ?? model.status) : "\(model.cachedRowCount) 行 · 当前页查找／查看",
                emptyState: model.preview?.isTruncated == true ? "结果超过预览上限，请缩小查询范围" : "加载成功 · 没有数据",
                history: history, restoreHistory: restoreHistory, onEndEditing: { editorFocused = false },
                onFindPresentationChange: { presented in
                    findingResults = presented
                    if presented { editorFocused = false }
                }, timestampScope: model.resultID.uuidString,
                exportScopeDescription: model.preview?.isTruncated == true ? "当前查询预览（已截断）" : "当前查询结果",
                editing: model.editing, editingPage: model.editingPage, readOnlyReason: model.editing?.editingRestriction ?? model.editingMessage, dataRevision: model.resultRevision.uuidString,
                tableExportSnapshot: model.queryExportSnapshot, retainedViewport: model.resultViewport, queryPagination: model)
                .id(model.selectedResultID)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("SQL 查询").navigationBarTitleDisplayMode(.inline)
        .alert("无法格式化 SQL", isPresented: Binding(get: { formatting.errorMessage != nil }, set: { if !$0 { formatting.errorMessage = nil } })) {
        } message: { Text(formatting.errorMessage ?? "") }
        .sheet(isPresented: $showingSnippets) { MobileSQLSnippetsView(store: snippets) }
        .sheet(item: $model.sqlConfirmation) { confirmation in
            NavigationStack {
                ScrollView { Text(confirmation.sql).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                    .navigationTitle("确认执行 SQL").navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 8) {
                            Text(confirmation.requiresUnlock ? "执行将关闭安全锁。请核对目标数据库、WHERE 条件及事务边界。" : "请核对目标数据库、WHERE 条件及事务边界。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(confirmation.configuration.database ?? "未选择数据库").font(.caption.weight(.semibold))
                            Button(confirmation.requiresUnlock ? "关闭安全锁并执行" : "确认执行", role: .destructive) { model.confirmSQL() }
                                .buttonStyle(.borderedProminent).accessibilityIdentifier("confirmSQLWrite")
                        }.frame(maxWidth: .infinity).padding().background(.bar)
                    }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { model.sqlConfirmation = nil } } }
            }
        }
        .onChange(of: model.editorConfiguration, initial: true) { _, configuration in formatting.cancel(); editorSchema.configure(configuration) }
        .onChange(of: model.resultID) { _, _ in
            editorSchema.invalidate()
            #if DEBUG
            if !ranEditorProbe, model.result != nil, ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SQL_EDITOR"] == "1" {
                ranEditorProbe = true
                let snippetTrigger = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SQL_SNIPPET"]
                model.sql = snippetTrigger ?? "SELECT u.us FROM admin_user u"
                model.executionInput.selection = .init(location: snippetTrigger == nil
                    ? (model.sql as NSString).range(of: "u.us").upperBound : model.sql.utf16.count, length: 0)
                editorFocused = true
            }
            #endif
        }
        .onChange(of: model.schemaRevision) { _, _ in editorSchema.invalidate() }
        .onDisappear { formatting.cancel(); editorSchema.invalidate() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase != .inactive { editorSchema.setBackgrounded(phase == .background) }
            if phase == .background { formatting.cancel() }
        }
        .toolbarTitleMenu { if model.statementResults.count > 1 { resultChoices } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("执行选区或当前语句") { model.execute() }.keyboardShortcut(.return, modifiers: .command)
                    Button("执行整个文稿") { model.executeAll() }.keyboardShortcut(.return, modifiers: [.command, .shift])
                } label: { Image(systemName: "play.fill") } primaryAction: { model.execute() }
                    .accessibilityLabel(model.executionInput.selection.length > 0 ? "执行所选" : "执行当前语句")
                    .disabled(!model.canExecute || model.isLoading).accessibilityIdentifier("executeQuery")
            }
        }
    }
    @ViewBuilder private var resultChoices: some View {
        Picker("查询结果", selection: Binding(get: { model.selectedResultID }, set: { _ = model.selectResult($0) })) {
            ForEach(model.statementResults) { result in Text(result.title).tag(result.id) }
        }.disabled(model.isLoading || model.isLoadingEditing)
    }

}
