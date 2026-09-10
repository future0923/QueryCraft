import SwiftUI

struct WorkspaceSidebar: View {
    @Bindable var model: WorkspaceModel
    let savedQueryActions: WorkspaceSavedQueryActions
    let openDatabaseObject: @MainActor (
        WorkspaceDatabaseObjectSelection
    ) -> Void
    let openRedisKey: @MainActor (RedisKeyReference) -> Void
    let renameRedisKey: @MainActor (RedisKeyReference) -> Void
    let openDatabaseObjectTab: @MainActor (
        WorkspaceDatabaseObjectSelection,
        WorkspaceDatabaseObjectDetailTab
    ) -> Void
    let tableDidRename: @MainActor (
        WorkspaceDatabaseObjectSelection,
        WorkspaceDatabaseObjectSelection
    ) -> Void
    let tableDidDelete: @MainActor (
        WorkspaceDatabaseObjectSelection
    ) -> Void
    let createTable: @MainActor (String) -> Void
    let showDatabasePicker: @MainActor () -> Void

    @State private var tableEditor: WorkspaceDatabaseTableEditor?
    @State private var tablePendingDelete: WorkspaceDatabaseObjectSelection?
    @State private var tablePendingDeleteAfterUnlock:
        WorkspaceDatabaseObjectSelection?
    @State private var tableMutationErrorMessage: String?
    @State private var tableDeletionTask: Task<Void, Never>?
    @State private var showsIndexCreation = false
    @State private var showsIndexTemplateManager = false
    @State private var indexPendingDelete: WorkspaceDatabaseObjectSelection?
    @State private var indexPendingUnlock: WorkspaceDatabaseObjectSelection?
    @State private var showsIndexUnlock = false
    @State private var indexDeletionMessage: String?

    var body: some View {
        Group {
            if model.databaseType == .redis {
                VStack(spacing: 0) {
                    RedisKeySearchBar(
                        text: $model.searchText,
                        isExactSearch: $model.isRedisKeyExactSearch,
                        submit: model.submitRedisKeySearch,
                        cancel: { model.searchText = "" }
                    )

                    WorkspaceRedisSidebar(
                        model: model,
                        openKey: openRedisKey,
                        renameKey: renameRedisKey
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    WorkspaceSidebarTabBar(selection: $model.sidebarMode)

                    HStack(spacing: 4) {
                        WorkspaceGridSearchField(
                            text: $model.searchText,
                            placeholder: searchPlaceholder,
                            focusRequest: 0,
                            submit: {},
                            cancel: { model.searchText = "" },
                            accessibilityIdentifier: "sidebarSearchField"
                        )
                        if model.databaseType == .elasticsearch,
                           model.sidebarMode == .items
                        {
                            Toggle(
                                AppCopy.current.text(
                                    "显示系统索引",
                                    "Show System Indices"
                                ),
                                isOn: $model.showsElasticsearchSystemResources
                            )
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .help(
                                AppCopy.current.text(
                                    "显示系统索引",
                                    "Show System Indices"
                                )
                            )
                            .accessibilityIdentifier(
                                "elasticsearchSystemIndicesToggle"
                            )
                        }
                    }
                    .controlSize(.regular)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)

                    switch model.sidebarMode {
                    case .items:
                        itemsList
                    case .queries:
                        queriesList
                    }
                }
            }
        }
        .navigationTitle(
            model.databaseContextName
                ?? AppCopy.current.text("数据库", "Database")
        )
        .accessibilityIdentifier("objectBrowser")
        .sheet(item: $indexPendingDelete) { selection in
            WorkspaceElasticsearchIndexDeletionSheet(selection: selection, model: model,
                didDelete: tableDidDelete, dismiss: { indexPendingDelete = nil })
        }
        .alert(AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"), isPresented: $showsIndexUnlock) {
            Button(AppCopy.current.text("允许此工作区进行更改", "Allow Changes for This Workspace"), role: .destructive) {
                model.safetyLock.disable()
                indexPendingDelete = indexPendingUnlock
                indexPendingUnlock = nil
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) { indexPendingUnlock = nil }
        } message: {
            Text(AppCopy.current.text("安全锁将保持停用，直到此工作区关闭。下一步需要输入索引名称，确认永久删除其中的全部文档。",
                "Safety Lock will remain disabled until this workspace closes. Next, enter the index name to confirm permanent deletion of all its documents."))
        }
        .alert(AppCopy.current.text("无法删除索引", "Unable to Delete Index"),
            isPresented: Binding(get: { indexDeletionMessage != nil }, set: { if !$0 { indexDeletionMessage = nil } })) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
        } message: { Text(indexDeletionMessage ?? "") }
        .sheet(isPresented: $showsIndexCreation) {
            WorkspaceElasticsearchIndexCreationSheet(
                model: model,
                openIndex: { name in
                    guard let databaseName = model.databaseContextName else { return }
                    let kind: WorkspaceDatabaseObjectKind
                    if case .loaded(let objects) = model.currentDatabase?.objectsState,
                       let object = objects.first(where: { $0.name == name }) {
                        kind = object.kind
                    } else {
                        kind = .elasticsearchIndex
                    }
                    showsIndexCreation = false
                    model.searchText = ""
                    model.sidebarMode = .items
                    model.isElasticsearchIndexGroupExpanded = true
                    if name.hasPrefix(".") { model.showsElasticsearchSystemResources = true }
                    openDatabaseObjectTab(
                        WorkspaceDatabaseObjectSelection(databaseName: databaseName, objectName: name, kind: kind),
                        .structure
                    )
                },
                dismiss: { showsIndexCreation = false }
            )
        }
        .sheet(isPresented: $showsIndexTemplateManager) {
            WorkspaceElasticsearchIndexTemplateManagerSheet(
                model: model,
                dismiss: { showsIndexTemplateManager = false }
            )
        }
        .sheet(item: $tableEditor) { editor in
            switch editor {
            case let .rename(selection):
                WorkspaceDatabaseTableRenameSheet(
                    selection: selection,
                    model: model,
                    didRename: tableDidRename,
                    dismiss: { tableEditor = nil }
                )
            }
        }
        .alert(
            AppCopy.current.text("删除表？", "Delete Table?"),
            isPresented: deleteConfirmationPresentation,
            presenting: tablePendingDelete
        ) { selection in
            Button(
                AppCopy.current.text("删除", "Delete"),
                role: .destructive
            ) {
                requestDeleteTable(selection)
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: { selection in
            Text(
                AppCopy.current.text(
                    "将永久删除表“\(selection.objectName)”及其中的所有数据。此操作无法撤销。",
                    "This permanently deletes the “\(selection.objectName)” table and all of its data. This action cannot be undone."
                )
            )
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: deleteSafetyLockPresentation
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                guard let selection = tablePendingDeleteAfterUnlock else {
                    return
                }
                tablePendingDeleteAfterUnlock = nil
                model.safetyLock.disable()
                deleteTable(selection)
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                tablePendingDeleteAfterUnlock = nil
            }
        } message: {
            Text(
                AppCopy.current.text(
                    "删除表会永久移除表和其中的数据。安全锁将保持停用，直到此工作区关闭。",
                    "Dropping a table permanently removes it and its data. Safety Lock will remain disabled until this workspace closes."
                )
            )
        }
        .alert(
            AppCopy.current.text("无法删除表", "Unable to Delete Table"),
            isPresented: tableMutationErrorPresentation
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(tableMutationErrorMessage ?? "")
        }
        .onDisappear {
            tableDeletionTask?.cancel()
        }
    }

    @ViewBuilder
    private var itemsList: some View {
        if model.connectionState == .connected,
           model.currentDatabase == nil
        {
            WorkspaceNoDatabaseSidebar(
                showDatabasePicker: showDatabasePicker
            )
        } else {
            VStack(spacing: 0) {
                List(selection: sidebarSelection) {
                    switch model.connectionState {
                    case .connecting:
                        Label(
                            AppCopy.current.text("正在连接…", "Connecting..."),
                            systemImage: "network"
                        )
                        .foregroundStyle(.secondary)

                    case .connected:
                        if let database = model.currentDatabase {
                            WorkspaceDatabaseItems(
                                database: database,
                                model: model,
                                openObjectTab: openDatabaseObjectTab,
                                renameTable: {
                                    tableEditor = .rename($0)
                                },
                                deleteTable: {
                                    tablePendingDelete = $0
                                },
                                deleteIndex: requestDeleteIndex
                            )
                        }

                    case .failed:
                        Label(
                            AppCopy.current.text(
                                "连接已断开",
                                "Disconnected"
                            ),
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.sidebar)
                .scrollIndicators(.hidden)
                .scrollContentBackground(.hidden)

                if model.databaseType == .postgresql {
                    WorkspacePostgreSQLSchemaFooter(
                        schemas: model.availableSchemas,
                        selectedSchema: model.selectedSchema,
                        selectSchema: { schema in
                            model.selectSchema(schema)
                        },
                        addTable: showCreateTable
                    )
                } else if model.databaseType == .elasticsearch {
                    HStack(spacing: 8) {
                        WorkspaceInlineIconButton(
                            systemImageName: "plus",
                            title: AppCopy.current.text("创建索引", "Create Index"),
                            action: { showsIndexCreation = true }
                        )
                        .accessibilityIdentifier("createElasticsearchIndex")
                        .disabled(model.connectionState != .connected)
                        Text(AppCopy.current.text("创建索引", "Create Index"))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        WorkspaceInlineIconButton(
                            systemImageName: "doc.text.magnifyingglass",
                            title: AppCopy.current.text("管理索引模板", "Manage Index Templates"),
                            action: { showsIndexTemplateManager = true }
                        )
                        .accessibilityIdentifier("manageElasticsearchIndexTemplates")
                        .disabled(model.connectionState != .connected)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                } else if model.databaseType != .elasticsearch,
                          let tableCount
                {
                    WorkspaceDatabaseObjectFooter(
                        tableCount: tableCount,
                        addTable: showCreateTable
                    )
                }
            }
        }
    }

    private var queriesList: some View {
        List {
            if let message = model.savedQueryLoadErrorMessage {
                Label(
                    AppCopy.current.text(
                        "无法加载已保存查询",
                        "Unable to Load Saved Queries"
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
                .help(message)
            }

            if !model.visibleSavedQueries.isEmpty {
                WorkspaceSavedQueryGroup(
                    title: AppCopy.current.text("未分组", "Ungrouped"),
                    queries: model.visibleSavedQueries,
                    databaseNames: [],
                    actions: savedQueryActions,
                    allowsMoving: false
                )
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.savedQueryLoadErrorMessage == nil,
               model.visibleSavedQueries.isEmpty
            {
                VStack {
                    Spacer(minLength: 0)
                    Text(
                        model.searchText.isEmpty
                            ? AppCopy.current.text(
                                "没有已保存查询",
                                "No saved queries"
                            )
                            : AppCopy.current.text(
                                "没有匹配的查询",
                                "No matching queries"
                            )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("emptySavedQueriesMessage")
            }
        }
    }

    private var searchPlaceholder: String {
        switch model.sidebarMode {
        case .items:
            AppCopy.current.text("搜索项目", "Search items")
        case .queries:
            AppCopy.current.text("搜索查询", "Search queries")
        }
    }

    private var tableCount: Int? {
        guard let database = model.currentDatabase,
              case let .loaded(objects) = database.objectsState
        else {
            return nil
        }
        return objects.count { $0.kind == .table }
    }

    private var sidebarSelection: Binding<WorkspaceDatabaseObjectSelection?> {
        Binding(
            get: { model.sidebarSelection },
            set: { selection in
                guard let selection else {
                    model.sidebarSelection = nil
                    return
                }
                openDatabaseObject(selection)
            }
        )
    }

    private var deleteConfirmationPresentation: Binding<Bool> {
        Binding(
            get: { tablePendingDelete != nil },
            set: { isPresented in
                if !isPresented { tablePendingDelete = nil }
            }
        )
    }

    private var deleteSafetyLockPresentation: Binding<Bool> {
        Binding(
            get: { tablePendingDeleteAfterUnlock != nil },
            set: { isPresented in
                if !isPresented { tablePendingDeleteAfterUnlock = nil }
            }
        )
    }

    private var tableMutationErrorPresentation: Binding<Bool> {
        Binding(
            get: { tableMutationErrorMessage != nil },
            set: { isPresented in
                if !isPresented { tableMutationErrorMessage = nil }
            }
        )
    }

    private func showCreateTable() {
        guard let databaseName = model.databaseContextName else { return }
        createTable(databaseName)
    }

    private func requestDeleteIndex(_ selection: WorkspaceDatabaseObjectSelection) {
        guard WorkspaceIndexDeletionWorker.offersDeletion(selection), model.connectionState == .connected else { return }
        guard !model.elasticsearchHasPendingChanges() else {
            indexDeletionMessage = WorkspaceIndexDeletionError.pendingChanges.localizedDescription
            return
        }
        if model.safetyLock.isEnabled {
            indexPendingUnlock = selection
            showsIndexUnlock = true
        } else {
            indexPendingDelete = selection
        }
    }

    private func requestDeleteTable(
        _ selection: WorkspaceDatabaseObjectSelection
    ) {
        if model.safetyLock.isEnabled {
            tablePendingDeleteAfterUnlock = selection
        } else {
            deleteTable(selection)
        }
    }

    private func deleteTable(
        _ selection: WorkspaceDatabaseObjectSelection
    ) {
        guard tableDeletionTask == nil else { return }
        let mutation = WorkspaceDatabaseTableMutation.drop(
            selection: selection
        )
        tableDeletionTask = Task { @MainActor in
            defer { tableDeletionTask = nil }
            do {
                try await model.applyTableMutation(mutation)
                try Task.checkCancellation()
                tableDidDelete(selection)
            } catch is CancellationError {
                return
            } catch {
                tableMutationErrorMessage = error.localizedDescription
            }
        }
    }
}

private enum WorkspaceDatabaseTableEditor: Identifiable {
    case rename(WorkspaceDatabaseObjectSelection)

    var id: String {
        switch self {
        case let .rename(selection):
            "rename:\(selection.id)"
        }
    }
}
