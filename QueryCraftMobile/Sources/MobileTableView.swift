import SwiftUI

struct MobileTableView: View {
    @Bindable var model: MobileBrowserModel
    let profileID: UUID
    var schema: MobileSchemaController? = nil
    var tableActions: MobileTableActionController? = nil
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var filterDraft: MobileTableFilterDraft?
    @State private var ranFilterEditorProbe = false
    var body: some View {
        VStack(spacing: 0) {
            if model.tab == .data {
                MobileResultsView(data: displayData,
                    revision: model.revision.uuidString + ".data." + (model.currentChanges?.revision.uuidString ?? ""),
                    widthKey: profileID.uuidString + "." + (model.selectedObject?.id ?? ""),
                    hasLoaded: model.snapshot != nil, isLoading: model.isLoadingTable, errorMessage: model.tableError,
                    status: model.currentChanges?.editingRestriction ?? dataStatus,
                    emptyState: model.snapshot?.filter.isActive == true ? "没有符合筛选条件的数据" : "加载成功 · 没有数据",
                    tableActions: tableActions, pagination: model, onEditFilter: presentFilter,
                    pageContext: model.snapshot.map(MobileGridPageContext.init(page:)),
                    exportName: model.snapshot?.object.name ?? "table-data",
                    exportScopeDescription: "当前表页",
                    exportTableIdentifierParts: model.snapshot.map { [$0.object.database, $0.object.name] },
                    editing: model.currentChanges, editingPage: model.snapshot, readOnlyReason: model.currentChanges?.editingRestriction,
                    dataRevision: model.revision.uuidString,
                    tableExportSnapshot: model.dataExportSnapshot())
            } else { MobileStructureView(model: model, controller: schema) }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(model.selectedObject?.name ?? "表").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if model.tab == .structure, let tableActions, let object = model.selectedObject, object.kind == .table {
                ToolbarItem(placement: .primaryAction) {
                    Menu { MobileTableActionMenu(controller: tableActions, object: object) }
                    label: { Label("表操作", systemImage: "ellipsis") }
                }
            }
        }
        .toolbarTitleMenu {
            Picker("查看", selection: $model.tab) {
                ForEach(MobileBrowserModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        }
        // Compact navigation has a native back route to the catalog. Keep iPad's
        // small top tabs when its sidebar and detail are both visible.
        .toolbar(horizontalSizeClass == .compact || verticalSizeClass == .compact ? .hidden : .visible, for: .tabBar)
        .onChange(of: model.tab) { _, _ in model.loadTable() }
        .onChange(of: model.pageSize) { _, _ in model.loadTable(offset: 0) }
        .onChange(of: model.selectedObject?.id) { _, _ in filterDraft = nil }
        .sheet(item: $filterDraft) { draft in
            MobileTableFilterEditor(draft: draft) { filter in
                try model.applyFilter(filter, objectID: draft.object.id)
            }
        }
        .onChange(of: model.revision, initial: true) { _, _ in
            #if DEBUG
            if !ranFilterEditorProbe, model.columns != nil, ProcessInfo.processInfo.environment["QUERYCRAFT_PROOF_FILTER_EDITOR"] == "1" {
                ranFilterEditorProbe = true; presentFilter()
            }
            #endif
        }
    }
    private var displayData: MobileGridData {
        if let page = model.snapshot, let changes = model.currentChanges { return changes.displayData(page: page, details: columnDetails) }
        return .init(preview: model.snapshot?.preview, details: columnDetails)
    }
    private func presentFilter() {
        guard let object = model.selectedObject, let columns = model.columns, !columns.isEmpty else { return }
        filterDraft = .init(object: object, columns: columns, filter: model.dataFilter)
    }
    private var columnDetails: [String]? {
        model.snapshot.map { MobileColumnDetails.resolve(result: $0.preview.result, object: $0.object, columns: $0.columns) }
    }
    private var dataStatus: String {
        guard let page = model.snapshot else { return "" }
        let rows = page.preview.result.rows.count
        let range = rows == 0 ? "0 行" : "\(page.offset + 1)–\(page.offset + rows) 行"
        return range + (page.filter.isActive ? " · 已筛选" : "") + (page.hasStableOrder ? "" : " · 无主键，跨页顺序可能变化")
    }
}
