import SwiftUI
import QueryCraftMobileCore

struct MobileElasticsearchWorkspaceView: View {
    @Bindable var app: MobileApplicationModel
    @Bindable var model: MobileElasticsearchWorkspace
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var column = NavigationSplitViewColumn.sidebar
    init(app: MobileApplicationModel, model: MobileElasticsearchWorkspace) {
        self.app = app; self.model = model
        _column = State(initialValue: model.selected == nil && !model.showsConsole ? .sidebar : .detail)
    }
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            List {
                ForEach([WorkspaceDatabaseObjectKind.elasticsearchIndex, .elasticsearchAlias, .elasticsearchDataStream], id: \.self) { kind in
                    Section(kind == .elasticsearchIndex ? "索引" : kind == .elasticsearchAlias ? "Alias" : "Data Stream") {
                        ForEach(model.visibleObjects.filter { $0.kind == kind }) { object in
                            Button { model.select(object); column = .detail } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(object.name).foregroundStyle(.primary).lineLimit(1)
                                    if let summary = object.summary {
                                        Text([summary.documentCount.map { "\($0) 篇文档" }, summary.health].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.listRowBackground(model.selected?.id == object.id ? Color.accentColor.opacity(0.12) : nil)
                            .contextMenu { objectActions(object) }.disabled(!model.canNavigate)
                        }
                    }
                }
            }.listStyle(.plain)
            .overlay { if model.catalog != nil, model.visibleObjects.isEmpty, !model.isLoadingCatalog, model.catalogError == nil { ContentUnavailableView("没有匹配对象", systemImage: "magnifyingglass") } }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                HStack { ProgressView().controlSize(.small).opacity(model.isLoadingCatalog ? 1 : 0); Text(model.catalogError ?? "\(model.catalog?.count ?? 0) 个对象").font(.caption).lineLimit(2).foregroundStyle(model.catalogError == nil ? Color.secondary : .red); Spacer() }.padding(.horizontal).frame(height: 48).background(.bar)
            }
            .searchable(text: $model.search, prompt: "搜索索引、Alias、Data Stream")
            .navigationTitle(model.profile.name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("连接", systemImage: "chevron.left", action: app.showLibrary) }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button("新建索引", systemImage: "plus") { model.begin(.createIndex) }
                        Button("索引模板", systemImage: "doc.on.doc") { model.begin(.templates) }
                        Button("模拟索引模板", systemImage: "play.rectangle") { model.begin(.simulate) }
                    } label: { Image(systemName: "plus") }.disabled(!model.canNavigate)
                    Button("REST 控制台", systemImage: "terminal") { model.showsConsole = true; column = .detail }.disabled(model.action != nil || model.cellChanges.hasChanges)
                    if sizeClass == .compact, column == .sidebar { refresh }
                }
            }
        } detail: {
            Group {
                if model.showsConsole { MobileElasticsearchConsoleView(console: model.console) }
                else {
                    MobileResultsView(data: model.showsMapping ? model.mappingData : model.data,
                        revision: model.revision.uuidString + String(model.showsMapping), widthKey: model.profile.id.uuidString + (model.selected?.id ?? "") + String(model.showsMapping),
                        hasLoaded: model.showsMapping ? model.mapping != nil : model.page != nil, isLoading: model.isLoadingPage, errorMessage: model.pageError,
                        status: model.status, exportName: model.selected?.name ?? "es", exportScopeDescription: "当前已加载文档页", exportDialect: nil,
                        onOpenElasticsearchDocument: model.showsMapping ? nil : { model.begin(.document, row: $0) }, elasticsearchPagination: model.showsMapping ? nil : model, tableExportSnapshot: model.showsMapping ? nil : model.exportSnapshot, retainedViewport: model.viewport)
                        .overlay { if model.selected == nil { ContentUnavailableView("选择对象", systemImage: "externaldrive") } }
                }
            }
            .navigationTitle(model.showsConsole ? "REST 控制台" : model.selected?.name ?? "Elasticsearch").navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Button("数据") { model.showsConsole = false; model.showsMapping = false }
                Button("Mapping") { model.showsConsole = false; model.showsMapping = true }
                Button("REST 控制台") { model.showsConsole = true }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.cellChanges.hasChanges {
                        Button("待提交修改", systemImage: "square.and.pencil") { model.begin(.cellChanges) }.accessibilityIdentifier("elasticsearchPendingChanges")
                    }
                    if !model.showsConsole, let object = model.selected {
                        Menu {
                            objectActions(object)
                            Button("批量删除当前页文档", systemImage: "trash") { model.begin(.batchDelete) }
                            Button("服务端筛选", systemImage: "line.3.horizontal.decrease") { model.showsFilter = true }
                            Menu("排序") {
                                Button("默认顺序") { model.setSort(.none) }
                                ForEach((model.mapping?.fieldCapabilities ?? []).filter { $0.isAggregatable && !$0.hasTypeConflict }) { field in
                                    Menu(field.path) { Button("升序") { model.setSort(.ascending(columnName: field.path)) }; Button("降序") { model.setSort(.descending(columnName: field.path)) } }
                                }
                            }
                            Menu("每页条数") { ForEach([25,50,100,200,500], id: \.self) { size in Button("\(size)") { model.setPageSize(size) } } }
                        } label: { Image(systemName: "ellipsis.circle") }.disabled(!model.canNavigate || model.isLoadingPage)
                    }
                    if sizeClass == .regular || column == .detail { refresh }
                }
            }
        }
        .sheet(item: $model.action) { action in MobileElasticsearchActionView(action: action) }
        .sheet(isPresented: $model.showsFilter) { MobileElasticsearchFilterView(model: model) }
        .onChange(of: column) { _, next in if sizeClass == .compact, next == .sidebar, model.canNavigate { model.select(nil); model.showsConsole = false } }
    }
    @ViewBuilder private func objectActions(_ object: WorkspaceDatabaseObject) -> some View {
        Button("新建文档", systemImage: "doc.badge.plus") { model.select(object); model.begin(.createDocument) }
        Button("粘贴多篇文档", systemImage: "doc.on.clipboard") { model.select(object); model.begin(.pasteDocuments) }
        Button("编辑 Mapping", systemImage: "square.and.pencil") { model.select(object); model.begin(.mapping) }
        Button("设置与统计", systemImage: "slider.horizontal.3") { model.select(object); model.begin(.settings) }
        if object.kind != .elasticsearchDataStream { Button("Alias 绑定", systemImage: "link") { model.select(object); model.begin(.aliases) } }
        if object.kind == .elasticsearchIndex, !object.name.hasPrefix(".ds-") {
            Button("删除索引", systemImage: "trash", role: .destructive) { model.select(object); model.begin(.deleteIndex) }
        }
    }
    private var refresh: some View {
        HStack {
            if model.isLoading { Button("取消", systemImage: "stop.circle", action: model.cancel).labelStyle(.iconOnly) }
            Button("刷新", systemImage: "arrow.clockwise", action: model.refresh).labelStyle(.iconOnly).accessibilityIdentifier("refreshCurrentContent")
        }
    }
}
