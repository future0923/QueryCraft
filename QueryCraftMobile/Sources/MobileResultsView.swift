import SwiftUI
import QueryCraftMobileCore
import QueryCraftMobileTransport

struct MobileCellEditingPresentation: Identifiable {
    let id = UUID()
    let request: WorkspaceDatabaseDataCellEditRequest
    let changes: MobileTableChanges
    let page: MobileTableSnapshot
    let row: Int
    var validateContext: () throws -> Void = {}
}

struct MobileResultsView: View {
    let data: MobileGridData
    let revision: String
    let widthKey: String
    let hasLoaded: Bool
    let isLoading: Bool
    let errorMessage: String?
    var status = ""
    var emptyState = "加载成功 · 没有数据"
    var tableActions: MobileTableActionController? = nil
    var pagination: MobileBrowserModel?
    var history: [MobileQueryHistoryItem] = []
    var restoreHistory: ((MobileQueryHistoryItem) -> Void)?
    var onEndEditing: (() -> Void)?
    var onFindPresentationChange: ((Bool) -> Void)?
    var timestampScope: String? = nil
    var onEditFilter: (() -> Void)?
    var pageContext: MobileGridPageContext? = nil
    var exportName = "query-result"
    var exportScopeDescription = "当前查询结果"
    var exportDialect: WorkspaceSQLExportDialect? = .mysql
    var onOpenElasticsearchDocument: ((Int) -> Void)? = nil
    var elasticsearchPagination: MobileElasticsearchWorkspace? = nil
    var resourcePagination: MobileResourceModel? = nil
    var exportTableIdentifierParts: [String]? = nil
    var editing: MobileTableChanges? = nil
    var editingPage: MobileTableSnapshot? = nil
    var readOnlyReason: String? = nil
    var dataRevision: String? = nil
    var tableExportSnapshot: MobileDataExportSnapshot? = nil
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var usesRecords = false
    @State private var interactionSource: MobileResultSource?
    @State private var cellPresentation: MobileResultCellPresentation?
    @State private var recordSelection: MobileRecordSelection?
    @State private var recordScrollID: Int?
    @State private var find = WorkspaceGridSearchController()
    @State private var findRevision: String?
    @State private var fullscreen: MobileFullscreenGridSelection?
    var retainedViewport: MobileGridViewport? = nil
    var queryPagination: MobileQueryModel? = nil
    @State private var localViewport = MobileGridViewport()
    private var viewport: MobileGridViewport { retainedViewport ?? localViewport }
    @State private var restorationID = UUID()
    @State private var insertDraft: MobileInsertDraft?
    @State private var pendingChanges: MobileTableChanges?
    @State private var selectedEditRow: Int?
    @State private var editMessage: String?
    @State private var ranEditProbe = false
    @State private var ranSurfaceProbe = false
    @State private var export: MobileDataExportModel?
    @FocusState private var searchFocused: Bool
    private var compactFindInput: Bool { find.isPresented && searchFocused && verticalSizeClass == .compact }

    var body: some View {
        let visible = data
        VStack(spacing: 0) {
            if find.isPresented {
                MobileGridSearchBar(controller: find, focused: $searchFocused)
                Divider()
            }
            Group {
                if usesRecords {
                    MobileRecordList(data: visible, revision: revision, scrollID: $recordScrollID) { row in
                        if let onOpenElasticsearchDocument { onOpenElasticsearchDocument(row); return }
                        selectedEditRow = row
                        recordSelection = .init(row: row, source: currentSource())
                    }.id(widthKey).id(pageContext)
                } else {
                    MobileDataGrid(data: visible, revision: revision, widthKey: widthKey,
                                   viewport: viewport, restorationID: restorationID, tracksViewport: fullscreen == nil,
                                   cellAccessibilityHint: editing == nil ? "轻点查看单元格" : "轻点查看或编辑单元格",
                                   searchController: find, revealsMatchOnResize: searchFocused,
                                   timestampScope: timestampScope, pageContext: pageContext) { row, column in
                        if let onOpenElasticsearchDocument { onOpenElasticsearchDocument(row); return }
                        selectedEditRow = row; editMessage = nil
                        cellPresentation = currentSource().cell(row: row, column: column)
                    }
                }
            }
            .background(usesRecords ? Color.clear : Color(uiColor: .systemBackground))
            .clipShape(.rect(cornerRadius: 14))
            .padding(.horizontal, 12)
            .overlay {
                if hasLoaded, visible.rows.isEmpty, !isLoading, errorMessage == nil {
                    Text(emptyState)
                        .foregroundStyle(.secondary).padding()
                }
            }
            if !compactFindInput { HStack(spacing: 8) {
                ProgressView().controlSize(.small).opacity(isLoading || editing?.isSubmitting == true ? 1 : 0)
                    .accessibilityHidden(!isLoading && editing?.isSubmitting != true)
                Text(editMessage ?? errorMessage ?? editing?.message ?? (editing?.isSubmitting == true ? "正在提交…" : (isLoading ? "正在加载…" : (hasLoaded ? status : "等待加载"))))
                    .font(.caption).foregroundStyle(errorMessage == nil && editMessage == nil && editing?.message == nil ? Color.secondary : Color.red).lineLimit(2)
                Spacer(minLength: 0)
                if let editing, editing.hasChanges {
                    Button { pendingChanges = editing } label: {
                        Label("\(editing.changeCount)", systemImage: "square.and.pencil").font(.caption)
                    }.accessibilityLabel("待提交改动，\(editing.changeCount) 行").accessibilityIdentifier("pendingChangesButton")
                }
                if let pagination { MobilePageNavigation(model: pagination) }
                if let es = elasticsearchPagination {
                    Button("上一页", systemImage: "chevron.left", action: es.previous).labelStyle(.iconOnly).disabled(!es.canNavigate || es.isLoadingPage || (es.page?.offset ?? 0) == 0)
                    Button("下一页", systemImage: "chevron.right", action: es.next).labelStyle(.iconOnly).disabled(!es.canNavigate || es.isLoadingPage || es.page?.hasNextPage != true)
                }
                if let resourcePagination {
                    if resourcePagination.profile.driver == .redis {
                        Menu {
                            Button("编辑值", systemImage: "square.and.pencil") { resourcePagination.beginRedisEditing() }
                                .disabled(!resourcePagination.canEditRedis)
                            Button("重命名", systemImage: "pencil") {
                                if let selected = resourcePagination.selected { resourcePagination.beginRedisKeyRename(selected) }
                            }.disabled(!resourcePagination.canManageRedisKeys || resourcePagination.selected == nil || resourcePagination.selected?.binaryKeyData != nil)
                            Button("整键 TTL", systemImage: "clock") {
                                if let selected = resourcePagination.selected { resourcePagination.beginRedisMetadataAction(selected, action: .expiration) }
                            }.disabled(!resourcePagination.canManageRedisKeys || resourcePagination.selected?.binaryKeyData != nil || resourcePagination.selected == nil)
                            Button("删除整个键", systemImage: "trash", role: .destructive) {
                                if let selected = resourcePagination.selected { resourcePagination.beginRedisMetadataAction(selected, action: .delete) }
                            }.disabled(!resourcePagination.canManageRedisKeys || resourcePagination.selected?.binaryKeyData != nil || resourcePagination.selected == nil)
                        } label: { Label("编辑", systemImage: "square.and.pencil") }
                        .disabled(resourcePagination.selected == nil || resourcePagination.selected?.binaryKeyData != nil || resourcePagination.isBackgrounded)
                        .accessibilityIdentifier("editRedisKey")
                    }
                    HStack(spacing: 6) {
                        Button("上一页", systemImage: "chevron.left", action: resourcePagination.previous).labelStyle(.iconOnly).disabled(!resourcePagination.canGoBack)
                        Button("下一页", systemImage: "chevron.right", action: resourcePagination.next).labelStyle(.iconOnly).disabled(resourcePagination.isLoadingDetails || resourcePagination.details?.hasNext != true)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
                if let queryPagination, queryPagination.hasCachePages {
                    HStack(spacing: 6) {
                        Button { queryPagination.pageCache(-1) } label: { Image(systemName: "chevron.left") }
                            .disabled(!queryPagination.canPageCache || queryPagination.cacheOffset == 0).accessibilityLabel("上一缓存页")
                        Text("\(queryPagination.cacheOffset + 1)–\(queryPagination.cacheOffset + data.rows.count)").font(.caption.monospacedDigit())
                        Button { queryPagination.pageCache(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(!queryPagination.canPageCache || queryPagination.cacheOffset + data.rows.count >= queryPagination.cachedRowCount).accessibilityLabel("下一缓存页")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }.padding(.horizontal, 12).frame(height: 44) }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(compactFindInput ? .hidden : .visible, for: .navigationBar)
        .sheet(item: $cellPresentation) { MobileResultCellSheet(presentation: $0) }
        .sheet(item: $recordSelection) { MobileRecordInspector(selection: $0) }
        .sheet(item: $insertDraft) { draft in if let editing { MobileInsertView(draft: draft, changes: editing) } }
        .sheet(item: $pendingChanges) { changes in MobilePendingChangesView(changes: changes) }
        .sheet(item: $export) { model in MobileDataExportView(model: model) }
        .fullScreenCover(item: $fullscreen, onDismiss: {
            restorationID = UUID(); viewport.activeOwner = nil
            selectedEditRow = interactionSource?.isCurrent == true ? gridSelectedRow : nil
        }) { selection in
            MobileFullscreenGrid(selection: selection)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("全屏表格", systemImage: "arrow.up.left.and.arrow.down.right") {
                        presentFullscreen(visible)
                    }.disabled(!hasLoaded || isLoading)
                    Picker("显示方式", selection: $usesRecords) {
                        Label("表格", systemImage: "tablecells").tag(false)
                        Label("记录", systemImage: "list.bullet.rectangle").tag(true)
                    }
                    Button("查找当前已加载数据", systemImage: "magnifyingglass") {
                        usesRecords = false
                        find.togglePresentation()
                        if !find.isPresented { searchFocused = false }
                    }.disabled(!hasLoaded || !find.canSearch)
                        .keyboardShortcut("f", modifiers: .command)
                    if let editing {
                        if !editing.isQueryResult {
                            Button("新增行", systemImage: "plus") {
                                do { insertDraft = try editing.newInsert() } catch { editMessage = error.localizedDescription }
                            }.disabled(isLoading || editing.isSubmitting || editing.needsVerification)
                        }
                        Button("暂存删除／恢复选中行", systemImage: "trash") {
                            if let page = editingPage, let row = selectedEditRow {
                                do { try editing.toggleDelete(page: page, row: row) }
                                catch { editMessage = error.localizedDescription }
                            }
                        }.disabled(selectedEditRow == nil || isLoading || editing.isSubmitting)
                        Button("待提交改动（\(editing.changeCount)）", systemImage: "square.and.pencil") { pendingChanges = editing }
                            .disabled(!editing.hasChanges)
                        Toggle("安全锁", isOn: Binding(get: { editing.safetyLock.isEnabled }, set: {
                            if $0 { editing.safetyLock.enable() } else { editing.safetyLock.disable() }
                        }))
                    }
                    if let tableActions, let object = pagination?.selectedObject, object.kind == .table {
                        Menu("表操作", systemImage: "tablecells.badge.ellipsis") {
                            MobileTableActionMenu(controller: tableActions, object: object)
                        }
                    }
                    if let pagination { MobilePageOptions(model: pagination, presentFilter: onEditFilter) }
                    Button(tableExportSnapshot == nil ? "导出已加载数据" : "导出数据", systemImage: "square.and.arrow.up") {
                        searchFocused = false
                        onEndEditing?()
                        export = .init(snapshot: tableExportSnapshot ?? .init(data: visible, name: exportName,
                            scopeDescription: exportScopeDescription, tableIdentifierParts: exportTableIdentifierParts, sqlDialect: exportDialect))
                    }.disabled(!hasLoaded || isLoading || (visible.rows.isEmpty && tableExportSnapshot == nil) || visible.columns.isEmpty)
                    if let restoreHistory {
                        Menu("查询历史", systemImage: "clock.arrow.circlepath") {
                            ForEach(history) { item in
                                Button((item.database.isEmpty ? "" : item.database + " · ") + String(item.sql.prefix(70))) {
                                    restoreHistory(item)
                                }
                            }
                        }.disabled(history.isEmpty)
                    }
                } label: { Label("显示、查找与排序", systemImage: "ellipsis") }
                .accessibilityIdentifier("resultOptions")
            }
        }
        .accessibilityIdentifier("queryResults")
        .onChange(of: revision, initial: true) { _, _ in
            if let row = selectedEditRow, !data.rows.indices.contains(row) { selectedEditRow = nil }
            editMessage = nil; updateFindSource(); synchronizeSource()
        }
        .onChange(of: sourceIdentity) { _, _ in selectedEditRow = nil; recordScrollID = nil; synchronizeSource() }
        .onChange(of: isLoading) { _, _ in synchronizeSource() }
        .onChange(of: readOnlyReason) { _, _ in synchronizeSource() }
        .onChange(of: usesRecords) { _, records in
            if records { searchFocused = false; find.dismiss() }
            else { selectedEditRow = gridSelectedRow }
        }
        .onChange(of: find.isPresented) { _, presented in onFindPresentationChange?(presented) }
        .onAppear { updateFindSource() }
        .onDisappear {
            if fullscreen == nil { find.clearSource(); findRevision = nil }
        }
        .onChange(of: hasLoaded && !isLoading, initial: true) { _, ready in
            #if DEBUG
            if ready, !ranSurfaceProbe {
                let scene = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_SURFACE"] ?? ""
                if scene.hasPrefix("record") {
                    ranSurfaceProbe = true; usesRecords = true
                    if scene != "records" { recordSelection = .init(row: 0, source: currentSource()) }
                } else if scene.hasPrefix("full") || ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_FULLSCREEN"] == "1" {
                    ranSurfaceProbe = true; presentFullscreen(visible)
                }
            }
            if ready, !ranEditProbe, let editing, let page = editingPage,
               (ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_DATA_EDIT"] == "1" || ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_QUERY_PENDING"] == "1"), !page.preview.result.rows.isEmpty {
                ranEditProbe = true
                if let request = try? editing.request(page: page, row: 0, column: min(1, page.preview.result.columns.count - 1)) {
                    if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_QUERY_PENDING"] == "1" {
                        try? editing.stage(request, text: "暂存示例 · 不写入数据库", mode: .value)
                        pendingChanges = editing
                    } else { cellPresentation = currentSource().cell(row: 0, column: min(1, page.preview.result.columns.count - 1)) }
                }
            }
            if ready, export == nil, !data.rows.isEmpty,
               ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_EXPORT"] == "1" {
                let model = MobileDataExportModel(snapshot: tableExportSnapshot ?? .init(data: data, name: exportName,
                    scopeDescription: exportScopeDescription, tableIdentifierParts: exportTableIdentifierParts, sqlDialect: exportDialect))
                if ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_EXPORT_ALL"] == "1", tableExportSnapshot != nil {
                    model.scope = .allTableRows
                }
                export = model
            }
            #endif
        }
    }

    private var gridSelectedRow: Int? {
        guard let path = viewport.selection, path.section > 0, data.rows.indices.contains(path.section - 1) else { return nil }
        return path.section - 1
    }
    private var sourceIdentity: MobileResultSourceIdentity { .init(widthKey: widthKey, timestampScope: timestampScope, page: pageContext) }
    private var sourceSnapshot: MobileResultSnapshot {
        .init(data: data, revision: revision, dataRevision: dataRevision ?? revision, identity: sourceIdentity,
              editing: editing, page: editingPage, isLoading: isLoading, readOnlyReason: readOnlyReason)
    }
    private func synchronizeSource() {
        guard let source = interactionSource else { return }
        source.receive(sourceSnapshot)
        if !source.isCurrent { interactionSource = nil }
    }
    private func currentSource() -> MobileResultSource {
        synchronizeSource()
        if let source = interactionSource { return source }
        let source = MobileResultSource(sourceSnapshot)
        interactionSource = source
        return source
    }

    private func updateFindSource() {
        guard findRevision != revision else { return }
        findRevision = revision
        find.update(source: MobileGridSearchSource(revision: UUID(), data: data))
        #if DEBUG
        if hasLoaded, !data.rows.isEmpty, let query = ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_GRID_FIND"], !query.isEmpty {
            find.query = query
            find.present()
        }
        #endif
    }

    private func presentFullscreen(_ visible: MobileGridData) {
        searchFocused = false
        onEndEditing?()
        let selection = MobileFullscreenGridSelection(data: visible, revision: revision, widthKey: widthKey, viewport: viewport,
                                                     timestampScope: timestampScope, pageContext: pageContext, source: currentSource(), elasticsearch: elasticsearchPagination)
        viewport.activeOwner = selection.id
        fullscreen = selection
    }
}

struct MobileCellSelection: Identifiable {
    var id: String { "\(row):\(column)" }
    let row: Int, column: Int
    let name: String
    let value: WorkspaceDatabaseDataCell
}

struct MobileCellInspector: View {
    let selection: MobileCellSelection
    var editingMessage: String? = nil
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let editingMessage { Text(editingMessage).font(.footnote).foregroundStyle(.secondary) }
                    Text("第 \(selection.row + 1) 行 · \(selection.name)").font(.headline)
                    switch selection.value {
                    case .null: Text("NULL").foregroundStyle(.secondary)
                    case .text(let value):
                        if value.isEmpty { Text("空字符串").foregroundStyle(.secondary) }
                        else {
                            let preview = WorkspaceDatabaseDataCell.boundedPreview(value, maximumCharacterCount: 16_384)
                            Text(preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            if preview != value { Text("预览前 16,384 个字符，可分享完整文本。").font(.footnote).foregroundStyle(.secondary) }
                        }
                        ShareLink(item: value) { Label("分享文本", systemImage: "square.and.arrow.up") }
                    case .binary(let count, let bytes):
                        Text("二进制 · \(count) bytes")
                        Text(bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Text("十六进制预览，最多 128 bytes").foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }.navigationTitle("单元格").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
        }.presentationDetents([.medium, .large])
    }
}

extension MobileGridData {
    init(columns: [String], details: [String], rows: [[String?]], cells: [[WorkspaceDatabaseDataCell]], metadata: [WorkspaceDatabaseDataColumn]? = nil) {
        self.columns = columns; self.details = details; self.rows = rows; self.cells = cells
        self.metadata = metadata ?? columns.enumerated().map { .init(id: $0.offset, name: $0.element) }
    }
}
