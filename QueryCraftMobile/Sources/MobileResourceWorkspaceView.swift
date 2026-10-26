import SwiftUI
import QueryCraftMobileCore

struct MobileResourceWorkspaceView: View {
    @Bindable var app: MobileApplicationModel
    @Bindable var model: MobileResourceModel
    @State private var groupsRedisKeys = true
    @State private var preferredColumn = NavigationSplitViewColumn.sidebar
    @Environment(\.horizontalSizeClass) private var sizeClass
    init(app: MobileApplicationModel, model: MobileResourceModel) {
        self.app = app; self.model = model
        _preferredColumn = State(initialValue: model.selected == nil ? .sidebar : .detail)
    }
    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            VStack(spacing: 0) {
                List {
                    if model.profile.driver == .redis, groupsRedisKeys, let tree = model.redisTree {
                        OutlineGroup(tree, children: \.outlineChildren) { node in
                            if let reference = node.reference {
                                resourceRow(.init(name: reference.name, kind: "key"), displayName: node.title)
                            } else {
                                Label {
                                    Text("\(node.title) (\(node.keyCount))").foregroundStyle(.primary)
                                } icon: {
                                    Image(systemName: "folder").foregroundStyle(.secondary)
                                }
                            }
                        }
                        ForEach((model.catalog ?? []).filter { $0.binaryKeyData != nil }) { resourceRow($0) }
                    } else {
                        ForEach(model.visibleResources) { resourceRow($0) }
                    }
                    HStack {
                        ProgressView().controlSize(.small).opacity(model.isLoadingCatalog ? 1 : 0)
                        Text(model.catalogError ?? (model.profile.driver == .redis ? "已加载 \(model.catalog?.count ?? 0) 个键" : "\(model.catalog?.count ?? 0) 个对象"))
                            .font(.caption).foregroundStyle(model.catalogError == nil ? Color.secondary : .red).lineLimit(2, reservesSpace: true)
                        Spacer(minLength: 0)
                    }.listRowSeparator(.hidden).accessibilityIdentifier("resourceCatalogStatus")
                }.listStyle(.plain).scrollContentBackground(.hidden)
                    .overlay {
                        if model.catalog != nil, model.visibleResources.isEmpty, !model.isLoadingCatalog, model.catalogError == nil {
                            ContentUnavailableView(model.catalogCursor == 0 ? "没有匹配对象" : "本批次无匹配键，扫描尚未结束", systemImage: "magnifyingglass")
                        }
                    }

            }
            .mobileCanvas()
            .navigationTitle(catalogTitle).navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker("逻辑数据库", selection: Binding(get: { model.scope ?? "" }, set: { model.selectScope($0) })) {
                    ForEach(model.scopes ?? [], id: \.self) { Text(model.profile.driver == .redis ? "DB " + $0 : $0).tag($0) }
                }.disabled(model.scopes == nil || model.hasPendingChanges || model.isBackgrounded)
            }
            .searchable(text: $model.search, placement: .navigationBarDrawer(displayMode: .always), prompt: model.profile.driver == .redis ? "搜索键名，如 user:*" : "搜索索引、别名和数据流")
            .onSubmit(of: .search) { if model.profile.driver == .redis { model.loadCatalog() } }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("连接", systemImage: "chevron.left", action: app.showLibrary) }
                if sizeClass == .compact && preferredColumn == .sidebar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        refreshButton
                        if model.profile.driver == .redis { redisCatalogActions }
                    }
                }
            }
        } detail: {
            VStack(spacing: 0) {
                if !model.structure, let chunk = model.details?.redisString {
                    MobileRedisStringValueView(model: model, chunk: chunk)
                        .id((model.scope ?? "") + "\0" + (model.selected?.id ?? ""))
                } else {
                MobileResultsView(data: (model.structure ? model.details?.structure : model.details?.data) ?? .init(columns: [], rows: []),
                    revision: model.revision.uuidString + String(model.structure),
                    widthKey: model.profile.id.uuidString + (model.selected?.id ?? "") + String(model.structure),
                    hasLoaded: model.details != nil, isLoading: model.isLoadingDetails, errorMessage: model.detailError,
                    status: model.details?.status ?? "只读浏览", exportName: model.selected?.name ?? "data", exportDialect: nil, resourcePagination: model)
                }

            }
            .overlay {
                if model.selected == nil { ContentUnavailableView("选择对象", systemImage: "externaldrive", description: Text("从目录选择要浏览的对象。")) }
            }
            .mobileCanvas()
            .navigationTitle(model.selected?.name ?? model.profile.driver.title).navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Picker("查看", selection: $model.structure) { Text("数据").tag(false); Text(model.profile.driver == .redis ? "属性" : "Mapping").tag(true) }
            }
            .toolbar {
                if sizeClass == .regular || preferredColumn == .detail {
                    ToolbarItemGroup(placement: .primaryAction) {
                        refreshButton
                        if model.profile.driver == .redis { redisCatalogActions }
                    }
                }
            }
        }
        .tint(MobileAppearance.tint)
        .sheet(isPresented: Binding(get: { model.redisEditor != nil }, set: { if !$0 { model.closeRedisEditor() } })) {
            if let editor = model.redisEditor { MobileRedisEditorView(editor: editor, close: model.closeRedisEditor) }
        }
        .sheet(item: Binding(get: { model.redisKeyAction }, set: { if $0 == nil { model.closeRedisKeyAction() } })) { action in
            MobileRedisKeyActionView(action: action, close: model.closeRedisKeyAction)
        }
        .sheet(isPresented: Binding(get: { model.isRedisConsolePresented }, set: { if !$0 { model.closeRedisConsole() } })) {
            if let console = model.redisConsole { MobileRedisConsoleView(console: console, document: console.document, close: model.closeRedisConsole) }
        }
        .onChange(of: model.selected?.id) { _, value in
            if value != nil { preferredColumn = .detail }
        }
        .onChange(of: preferredColumn) { _, column in
            if sizeClass == .compact, column == .sidebar { model.select(nil) }
        }
    }
    private func resourceRow(_ resource: MobileResource, displayName: String? = nil) -> some View {
        Button { model.select(resource); preferredColumn = .detail } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName ?? resource.name).lineLimit(1).foregroundStyle(.primary)
                Text(resource.kind).font(.caption).foregroundStyle(.secondary)
            }
        }.listRowBackground(model.selected == resource ? MobileAppearance.selection : nil)
        .contextMenu {
            if model.profile.driver == .redis {
                Button("重命名", systemImage: "pencil") { model.beginRedisKeyRename(resource) }
                    .disabled(!model.canManageRedisKeys || resource.binaryKeyData != nil)
                Button("整键 TTL", systemImage: "clock") { model.beginRedisMetadataAction(resource, action: .expiration) }
                    .disabled(!model.canManageRedisKeys || resource.binaryKeyData != nil)
                Button("删除整个键", systemImage: "trash", role: .destructive) { model.beginRedisMetadataAction(resource, action: .delete) }
                    .disabled(!model.canManageRedisKeys || resource.binaryKeyData != nil)
            }
        }
    }
    private var catalogTitle: String {
        guard model.profile.driver == .redis else { return model.profile.name }
        return model.profile.name + " · " + (model.scope.map { "DB " + $0 } ?? "选择数据库")
    }
    private var redisCatalogActions: some View {
        Menu {
            if model.catalogCursor != 0 {
                Button("继续扫描", systemImage: "arrow.forward") { model.loadCatalog(more: true) }.disabled(model.isLoadingCatalog)
            }
            Menu {
                Toggle("按前缀分组", isOn: $groupsRedisKeys)
                Picker("键名匹配", selection: $model.redisSearchMode) {
                    ForEach(RedisKeySearchMatchMode.allCases) { Text($0.title).tag($0) }
                }
            } label: { Label("目录显示与匹配", systemImage: "line.3.horizontal.decrease") }
            .accessibilityIdentifier("redisCatalogOptions").disabled(model.hasPendingChanges)
            Button("命令", systemImage: "terminal") { model.beginRedisConsole() }
                .disabled(!model.canManageRedisKeys).accessibilityIdentifier("openRedisConsole")
            Menu {
                ForEach(RedisKeyCreationPlan.creatableTypes, id: \.self) { type in
                    Button(type.rawValue) { model.beginRedisKeyCreation(type) }
                }
            } label: { Label("新建键", systemImage: "plus") }
            .disabled(!model.canManageRedisKeys).accessibilityIdentifier("createRedisKey")
        } label: { Label("更多键操作", systemImage: "ellipsis") }
        .labelStyle(.iconOnly).accessibilityIdentifier("redisCatalogActions")
    }
    private var refreshButton: some View {
        Button(model.isLoading ? "取消" : "刷新", systemImage: model.isLoading ? "stop.circle" : "arrow.clockwise") {
            if model.isLoading { model.cancel() } else { model.refresh() }
        }.labelStyle(.iconOnly).accessibilityIdentifier("refreshCurrentContent")
    }
}
