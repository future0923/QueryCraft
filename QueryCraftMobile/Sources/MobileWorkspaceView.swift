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
                    Label("只读 SQL", systemImage: "lock").font(.caption).foregroundStyle(.secondary).fixedSize().layoutPriority(1)
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
                                    snippets: snippets.completionSources, snippetContext: snippetContext) { model.execute() }
                        .frame(height: verticalSizeClass == .compact ? 60 : 130).padding(.horizontal, 8).padding(.bottom, 8)
                        .accessibilityLabel("SQL 编辑器").accessibilityIdentifier("sqlEditor")
                }.background(Color(uiColor: .systemBackground), in: .rect(cornerRadius: 14))
            }.padding(.horizontal, 12).padding(.top, 8)
            if verticalSizeClass != .compact { HStack(alignment: .firstTextBaseline) {
                Text("查询结果").font(.subheadline.weight(.semibold))
                Spacer()
                Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(.horizontal, 18).frame(height: 48) } }
            MobileResultsView(data: model.displayData, revision: model.resultRevision.uuidString + (model.editing?.revision.uuidString ?? ""),
                widthKey: widthKey + ".query", hasLoaded: model.result != nil,
                isLoading: model.isLoading || model.isLoadingEditing, errorMessage: model.errorMessage,
                status: model.requiresResultReload ? (model.editingMessage ?? model.status) : "\(model.result?.rows.count ?? 0) 行 · 轻点查看或编辑",
                emptyState: model.preview?.isTruncated == true ? "结果超过预览上限，请缩小查询范围" : "加载成功 · 没有数据",
                history: history, restoreHistory: restoreHistory, onEndEditing: { editorFocused = false },
                onFindPresentationChange: { presented in
                    findingResults = presented
                    if presented { editorFocused = false }
                }, timestampScope: model.resultID.uuidString,
                exportScopeDescription: model.preview?.isTruncated == true ? "当前查询预览（已截断）" : "当前查询结果",
                editing: model.editing, editingPage: model.editingPage, readOnlyReason: model.editing?.editingRestriction ?? model.editingMessage, dataRevision: model.resultRevision.uuidString,
                tableExportSnapshot: model.preview.map { .init(data: .init(preview: $0, details: model.columnDetails), name: "query-result",
                    scopeDescription: $0.isTruncated ? "当前查询预览（已截断）" : "当前查询结果") })
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("SQL 查询").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingSnippets) { MobileSQLSnippetsView(store: snippets) }
        .onChange(of: model.editorConfiguration, initial: true) { _, configuration in editorSchema.configure(configuration) }
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
        .onDisappear { editorSchema.invalidate() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase != .inactive { editorSchema.setBackgrounded(phase == .background) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(model.executionInput.selection.length > 0 ? "执行所选" : "执行当前语句", systemImage: "play.fill") { model.execute() }
                    .disabled(!model.canExecute || model.isLoading)
                    .keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("executeQuery")
            }
        }
    }
}
