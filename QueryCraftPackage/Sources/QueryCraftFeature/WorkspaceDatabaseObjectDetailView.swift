import SwiftUI

struct WorkspaceDatabaseObjectDetailView: View {
    let selection: WorkspaceDatabaseObjectSelection
    let model: WorkspaceModel
    let contentRefreshRegistry: WorkspaceContentRefreshRegistry
    let pendingChangesRegistry: WorkspacePendingChangesRegistry
    let inspectorRegistry: WorkspaceInspectorRegistry
    let objectDetailTabRegistry: WorkspaceDatabaseObjectDetailTabRegistry

    @State private var selectedTab = WorkspaceDatabaseObjectDetailTab.data
    @State private var dataOffset = 0
    @State private var synchronizedDocumentPageLoadID: String?
    @State private var dataLimit: Int
    @State private var dataSort = WorkspaceDatabaseDataSort.none
    @State private var didResolveDefaultDataSort = false
    @State private var appliedDataFilter = WorkspaceDatabaseDataFilter.empty
    @State private var dataFilterEditor = WorkspaceDatabaseDataFilterEditor()
    @State private var dataFilterRevision = 0
    @State private var dataFilterSelectionID: String
    @State private var dataFilterDetailsTask: Task<Void, Never>?
    @State private var reloadRequest = 0
    @State private var pendingRefreshRequest: Int?
    @State private var refreshCompletionRequest = 0
    @State private var showsRefreshCompletion = false
    @State private var exportController = WorkspaceDataExportController()
    @State private var searchController = WorkspaceGridSearchController()
    @State private var pendingInspectorUpdates:
        [WorkspaceDatabaseInspectorPendingUpdate] = []
    @State private var cellEditErrorMessage = ""
    @State private var showsCellEditError = false
    @State private var rowInsertEditor =
        WorkspaceDatabaseDataRowInsertEditorState()
    @State private var rowInsertPreparationTask: Task<Void, Never>?
    @State private var rowInsertPreparationID: UUID?
    @State private var isPreparingRowInsert = false
    @State private var showsDisableSafetyLockForRowInsert = false
    @State private var rowInsertErrorMessage = ""
    @State private var showsRowInsertError = false
    @State private var selectedDataRowIndexes = IndexSet()
    @State private var documentInspectorModel =
        WorkspaceElasticsearchDocumentInspectorModel()
    @State private var documentCellEditor =
        WorkspaceElasticsearchDocumentCellEditor()
    @State private var documentInlineEditSnapshot: WorkspaceDocumentSnapshot?
    @State private var documentCellEditingLifetime = WorkspaceDataCellEditingLifetime()
    @State private var documentCellFailureMessage: String?
    @State private var documentCreationFailureMessage: String?
    @State private var documentCreationPresentation: WorkspaceElasticsearchCreationTablePresentation?
    @State private var documentDuplicationTask: Task<Void, Never>?
    @State private var documentDuplicationID: UUID?
    @State private var pendingDocumentDuplicationRowIndex: Int?
    @State private var pendingDocumentPaste: (WorkspaceGridPasteboardContent, [String], UUID?)?
    @State private var isPreparingDocumentDuplication = false
    @State private var showsDisableSafetyLockForDocumentCreation = false
    @State private var showsDisableSafetyLockForDocumentEdit = false
    @State private var showsDisableSafetyLockForDocumentDelete = false
    @State private var pendingDocumentDeletionRows = IndexSet()
    @State private var documentDeletionPreparationTask: Task<Void, Never>?
    @State private var documentDeletionPreparationID: UUID?
    @State private var isPreparingDocumentDeletion = false
    @State private var showsDocumentDraftNavigationBlocked = false
    @State private var showsDocumentCommitError = false
    @State private var documentCommitErrorMessage = ""
    @State private var showsDocumentDeleteError = false
    @State private var documentDeleteErrorMessage = ""
    @State private var documentDeletionFailureMessage: String?
    @State private var documentSubmissionID: UUID?
    @State private var documentDeletionRecoveryTask: Task<Void, Never>?
    @State private var showsDocumentConflict = false
    @State private var documentConflictError =
        WorkspaceDocumentEditingError.conflict
    @State private var pendingRowDeletes:
        [WorkspaceDatabaseInspectorPendingDelete] = []
    @State private var rowDeletePreparationTask: Task<Void, Never>?
    @State private var rowDeletePreparationID: UUID?
    @State private var isPreparingRowDelete = false
    @State private var rowDeleteErrorMessage = ""
    @State private var showsRowDeleteError = false
    @State private var pendingChangesSubmissionTask: Task<Void, Never>?
    @State private var pendingSchemaExecutionPlan:
        WorkspaceDatabaseSchemaExecutionPlan?
    @State private var isSubmittingPendingChanges = false
    @State private var schemaEditor = WorkspaceDatabaseSchemaEditorState()
    @State private var selectedSchemaColumnID: UUID?
    @State private var selectedSchemaIndexID: UUID?
    @State private var mappingEditor = WorkspaceElasticsearchMappingEditor()
    @State private var indexInspector = WorkspaceElasticsearchIndexInspectorModel()
    @State private var aliasEditor = WorkspaceElasticsearchAliasEditor()

    init(
        selection: WorkspaceDatabaseObjectSelection,
        model: WorkspaceModel,
        contentRefreshRegistry: WorkspaceContentRefreshRegistry,
        pendingChangesRegistry: WorkspacePendingChangesRegistry,
        inspectorRegistry: WorkspaceInspectorRegistry,
        objectDetailTabRegistry: WorkspaceDatabaseObjectDetailTabRegistry
    ) {
        self.selection = selection
        self.model = model
        self.contentRefreshRegistry = contentRefreshRegistry
        self.pendingChangesRegistry = pendingChangesRegistry
        self.inspectorRegistry = inspectorRegistry
        self.objectDetailTabRegistry = objectDetailTabRegistry
        _dataLimit = State(
            initialValue: ApplicationPreferences.shared.tableDataPageSize
        )
        _dataFilterSelectionID = State(initialValue: selection.id)
    }

    private var detailContent: some View {
        VStack(spacing: 0) {
            if isElasticsearchObject && selectedTab == .structure {
                WorkspaceElasticsearchEditableMappingView(editor: mappingEditor, workspace: model,
                    resource: .init(resource: selection.objectName, kind: selection.kind))
            } else {
            WorkspaceDatabaseObjectDetailContent(
                detailsState: model.selectedObjectDetailsState,
                indexesState: model.selectedObjectIndexesState,
                dataState: documentCreationPresentation?.dataState ?? model.selectedObjectDataState,
                availableTabs: availableTabs,
                selectedTab: selectedTab,
                retry: retry,
                sortData: sortData,
                appliedDataFilter: currentAppliedDataFilter,
                dataFilterEditor: dataFilterEditor,
                isDataFilterPresented: isCurrentDataFilterPresented,
                detailsStateForDataFilter: model.selectedObjectDetailsState,
                editDataFilter: presentDataFilter,
                clearDataFilter: clearDataFilter,
                closeDataFilter: dismissDataFilter,
                applyDataFilter: applyDataFilter,
                retryDataFilterDetails: loadFilterColumns,
                exportAllRowsProvider: model.dataExportAllRowsProvider(
                    for: selection,
                    sort: dataSort,
                    filter: currentAppliedDataFilter
                ),
                exportFileName: selection.objectName,
                exportController: exportController,
                searchController: searchController,
                prepareCellEdit: synchronousCellEditPreparer,
                prepareCellEditAsync: asynchronousCellEditPreparer,
                updateCellEdit: updateInlineCellEdit,
                pendingLoadedUpdates: pendingInspectorUpdates,
                rowInsertEditor: documentCreationPresentation?.rowInsertEditor ?? rowInsertEditor,
                updateRowInsertDraft: updateRowInsertDraft,
                submitRowInsert: requestPendingChangesSubmission,
                cancelRowInsert: cancelRowInsert,
                pendingDeleteRowIndexes: pendingDeleteRowIndexes,
                selectedDataRowIndexes: documentCreationPresentation?.selectedRowIndexes ?? selectedDataRowIndexes,
                rowActionKind: isElasticsearchObject
                    ? .elasticsearchDocument
                    : .tableRow,
                addRow: dataRowAdditionAction,
                duplicateRow: dataRowDuplicationAction,
                deleteRows: dataRowDeletionAction,
                pasteRows: canAddRowOrDocument ? beginPastingRows : nil,
                selectRowsForActions: selectRowsForActions,
                canEditSchema: model.schemaEditingDescriptor.canEdit
                    && selection.kind == .table
                    && !isSubmittingPendingChanges,
                schemaEditingDescriptor: model.schemaEditingDescriptor,
                schemaEditor: schemaEditor,
                tableOptions: $schemaEditor.tableOptions,
                selectedSchemaColumnID: $selectedSchemaColumnID,
                selectedSchemaIndexID: $selectedSchemaIndexID,
                addSchemaColumn: addSchemaColumn,
                duplicateSchemaColumn: duplicateSchemaColumn,
                updateSchemaColumn: updateSchemaColumn,
                setSchemaColumnPrimaryKey: setSchemaColumnPrimaryKey,
                deleteSchemaColumn: deleteSchemaColumn,
                addSchemaIndex: addSchemaIndex,
                duplicateSchemaIndex: duplicateSchemaIndex,
                updateSchemaIndex: updateSchemaIndex,
                deleteSchemaIndex: deleteSchemaIndex
            )
            }

            WorkspaceDatabaseDataProgressBar(
                isActive: selectedTab == .data && isDataWorkActive
            )

            WorkspaceDatabaseObjectDetailBottomBar(
                availableTabs: availableTabs,
                objectKind: selection.kind,
                selectedTab: Binding(get: { selectedTab }, set: { tab in
                    guard !indexInspector.isCommitting, !aliasEditor.isCommitting else { return }
                    selectedTab = tab
                }),
                page: (documentCreationPresentation?.dataState ?? model.selectedObjectDataState).page,
                countState: documentCreationPresentation?.countState ?? model.selectedObjectDataCountState,
                isFetching: (documentCreationPresentation?.dataState ?? model.selectedObjectDataState).isFetching,
                isStopped: (documentCreationPresentation?.dataState ?? model.selectedObjectDataState).isStopped,
                previousPage: previousDataPage,
                nextPage: nextDataPage,
                loadRange: loadDataRange,
                exportController: exportController,
                searchController: searchController,
                isDataFilterPresented: isCurrentDataFilterPresented,
                hasActiveDataFilter: currentAppliedDataFilter.isActive,
                isDataFilterDisabled: dataFilterDetailsTask != nil
                    && !isCurrentDataFilterPresented,
                toggleDataFilter: toggleDataFilter,
                isAddRowVisible: model.sessionCapabilities.supportsDataEditing
                    && (selection.kind == .table || isElasticsearchObject),
                isAddRowEnabled: canAddRowOrDocument,
                addRowDisabledReason: addRowDisabledReason,
                addRow: beginAddingRowOrDocument,
                isAddColumnEnabled: isElasticsearchObject ? mappingEditor.canAddFields : canAddSchemaColumn,
                addColumn: isElasticsearchObject ? addMappingField : addSchemaColumn,
                isAddIndexEnabled: canAddSchemaIndex,
                addIndex: addSchemaIndex,
                mappingActions: isElasticsearchObject
                    ? WorkspaceElasticsearchMappingActionsView(editor: mappingEditor, workspace: model)
                    : nil
            )
        }
    }

    private var observedContent: some View {
        detailContent
        .task(id: loadID + (isElasticsearchObject ? ":\(model.elasticsearchMutationRevision)" : "")) {
            await loadSelectedContentIfNeeded()
        }
        .task(id: "\(selection.id):\(reloadRequest):\(model.elasticsearchMutationRevision)") {
            guard isElasticsearchObject else { return }
            async let settings: Void = indexInspector.load(selection: selection, workspace: model)
            async let aliases: Void = aliasEditor.load(selection: selection, workspace: model)
            _ = await (settings, aliases)
        }
        .task(id: refreshCompletionRequest) {
            guard refreshCompletionRequest > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(1))
                showsRefreshCompletion = false
            } catch is CancellationError {
                // A newer refresh owns the completion feedback.
            } catch {
                showsRefreshCompletion = false
            }
        }
        .task(id: selectedTab) {
            guard selectedTab != .data else { return }
            await model.stopDataWork(for: selection, reason: .leftDataTab)
        }
        .task(id: WorkspaceDocumentInspectorLoadRequest(reference: selectedDocumentReference,
            serverRevision: model.elasticsearchMutationRevision)) {
            await documentInspectorModel.load(
                reference: selectedDocumentReference,
                serverRevision: model.elasticsearchMutationRevision,
                fetch: { reference in
                    try await model.fetchDocument(reference)
                }
            )
        }
        .onChange(of: selection.kind) { _, _ in
            if !availableTabs.contains(selectedTab) {
                selectedTab = .data
            }
        }
        .onChange(of: selection.id) { _, selectionID in
            resetDataState(for: selectionID)
        }
        .onChange(of: model.selectedObjectDataState.page?.revision) { _, _ in
            synchronizeDocumentPageOffset()
        }
        .onChange(of: selectedTab) { previous, selectedTab in
            if mappingEditor.hasChanges && selectedTab != .structure {
                self.selectedTab = previous; showsDocumentDraftNavigationBlocked = true; return
            }
            guard selectedTab != .data else { return }
            dismissDataFilter()
        }
        .onChange(of: model.selectedObjectDetailsState) { _, state in
            guard case let .loaded(details) = state else { return }
            schemaEditor.loadColumnsIfNeeded(
                details.columns,
                schemaChoices: details.schemaChoices
            )
            if let tableInformation = details.tableInformation {
                schemaEditor.loadTableOptionsIfNeeded(
                    tableInformation.tableOptions
                )
            }
        }
        .onChange(of: model.selectedObjectIndexesState) { _, state in
            guard case let .loaded(indexes) = state else { return }
            schemaEditor.loadIndexesIfNeeded(indexes)
        }
    }

    var body: some View {
        observedContent
        .alert(AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $indexInspector.showsUnlockConfirmation) {
            Button(AppCopy.current.text("允许此工作区进行更改", "Allow Changes for This Workspace"), role: .destructive) {
                indexInspector.confirmUnlock(workspace: model)
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) { indexInspector.cancelUnlock() }
        } message: {
            Text(AppCopy.current.text("索引设置将通过顶部工具栏预览和提交。安全锁将在此工作区关闭前保持停用。", "Preview and commit index settings from the top toolbar. Safety Lock will remain disabled until this workspace closes."))
        }
        .alert(AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $aliasEditor.showsUnlockConfirmation) {
            Button(AppCopy.current.text("允许此工作区进行更改", "Allow Changes for This Workspace"), role: .destructive) {
                aliasEditor.confirmUnlock(workspace: model)
            }
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                aliasEditor.cancelUnlock()
            }
        } message: {
            Text(AppCopy.current.text(
                "Alias 绑定更改将通过顶部工具栏预览和提交。安全锁将在此工作区关闭前保持停用。",
                "Preview and commit alias binding changes from the top toolbar. Safety Lock will remain disabled until this workspace closes."
            ))
        }
        .focusedSceneValue(
            \.workspaceDatabaseDataFilterPresentationActions,
            dataFilterPresentationActions
        )
        .focusedSceneValue(
            \.workspaceDatabaseDataRowActions,
            dataRowCommandActions
        )
        .focusedSceneValue(
            \.workspaceDatabaseSchemaRowActions,
            schemaRowCommandActions
        )
        .focusedSceneValue(
            \.workspaceDatabaseObjectDetailTabActions,
            objectDetailTabActions
        )
        .background {
            WorkspaceDatabaseDataRowKeyCommandHandler(
                actions: dataRowCommandActions,
                filterPresentationActions: dataFilterPresentationActions,
                objectDetailTabActions: objectDetailTabActions,
                isSuspended: isCurrentDataFilterPresented,
                schemaActions: schemaRowCommandActions,
                handlesSchemaActionsInDataGrid: isElasticsearchObject && selectedTab == .structure
            )
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsDisableSafetyLockForRowInsert
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                model.safetyLock.disable()
                startPendingChangesSubmission()
            }
            .keyboardShortcut(.defaultAction)
            Button(
                AppCopy.current.text("取消", "Cancel"),
                role: .cancel
            ) {}
            .keyboardShortcut(.cancelAction)
        } message: {
            Text(
                AppCopy.current.text(
                    pendingDataCommitMessage.zhHans,
                    pendingDataCommitMessage.en
                )
            )
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsDisableSafetyLockForDocumentCreation
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                model.safetyLock.disable()
                startPendingDocumentCreation()
            }
            .keyboardShortcut(.defaultAction)
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                pendingDocumentDuplicationRowIndex = nil
                pendingDocumentPaste = nil
            }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(AppCopy.current.text(
                "新文档会先进入待提交状态。安全锁将在此工作区关闭前保持停用。",
                "The new document will be staged before it is committed. Safety Lock will remain disabled until this workspace closes."
            ))
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsDisableSafetyLockForDocumentEdit
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                model.safetyLock.disable()
                startDocumentEditing()
            }
            .keyboardShortcut(.defaultAction)
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(AppCopy.current.text(
                "编辑后可预览并提交 Elasticsearch 文档替换请求。安全锁将在此工作区关闭前保持停用。",
                "You can preview and commit the Elasticsearch document replacement after editing. Safety Lock will remain disabled until this workspace closes."
            ))
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsDisableSafetyLockForDocumentDelete
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                model.safetyLock.disable()
                startPendingDocumentDeletion()
            }
            .keyboardShortcut(.defaultAction)
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {
                pendingDocumentDeletionRows = []
            }
            .keyboardShortcut(.cancelAction)
        } message: {
            Text(AppCopy.current.text(
                "所选文档会先标记为待删除，并保留各自的并发版本信息。安全锁将在此工作区关闭前保持停用。",
                "Selected documents will be staged for deletion with their concurrency versions. Safety Lock will remain disabled until this workspace closes."
            ))
        }
        .alert(
            documentNavigationBlockTitle,
            isPresented: $showsDocumentDraftNavigationBlocked
        ) {
            Button(documentNavigationBlockActionTitle, role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(documentNavigationBlockMessage)
        }
        .alert(
            documentConflictTitle,
            isPresented: $showsDocumentConflict
        ) {
            Button(AppCopy.current.text("重新加载", "Reload"), role: .destructive) {
                reloadDocumentAfterConflict()
            }
            Button(
                documentInspectorModel.isPendingDeletion
                    ? AppCopy.current.text("保留待删除状态", "Keep Pending Deletions")
                    : AppCopy.current.text("保留草稿", "Keep Draft"),
                role: .cancel
            ) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(documentConflictMessage)
        }
        .alert(
            AppCopy.current.text("无法保存文档", "Unable to Save Document"),
            isPresented: $showsDocumentCommitError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(documentCommitErrorMessage)
        }
        .alert(
            AppCopy.current.text("无法删除文档", "Unable to Delete Document"),
            isPresented: $showsDocumentDeleteError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(documentDeleteErrorMessage)
        }
        .alert(
            AppCopy.current.text("无法保存更改", "Unable to Save Changes"),
            isPresented: $showsCellEditError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(cellEditErrorMessage)
        }
        .alert(
            AppCopy.current.text("无法新增行", "Unable to Add Row"),
            isPresented: $showsRowInsertError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(rowInsertErrorMessage)
        }
        .alert(
            AppCopy.current.text("无法删除行", "Unable to Delete Row"),
            isPresented: $showsRowDeleteError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(rowDeleteErrorMessage)
        }
        .onAppear {
            syncSchemaEditorFromLoadedStates()
            publishContentRefreshActions()
            publishPendingChangesActions()
            publishDatabaseInspectorContext()
            objectDetailTabRegistry.update(
                objectDetailTabActions,
                for: contentID
            )
        }
        .onChange(of: contentRefreshActions) { _, actions in
            contentRefreshRegistry.update(actions, for: contentID)
        }
        .onChange(of: pendingChangesActions) { _, actions in
            if let actions {
                pendingChangesRegistry.update(actions, for: contentID)
            } else {
                pendingChangesRegistry.remove(for: contentID)
            }
        }
        .onChange(of: documentInspectorModel.cellChanges.retainedFields) { _, fields in
            guard isElasticsearchObject else { return }
            pendingInspectorUpdates.removeAll { pending in
                guard let reference = WorkspaceElasticsearchCellChangesModel.reference(for: pending.update) else { return true }
                return fields[reference]?.contains(pending.update.columnName) != true
            }
        }
        .onChange(of: documentInspectorModel.creations.projections) { previous, projections in
            for (id, projection) in projections where previous[id] != projection {
                rowInsertEditor.replaceDraftRow(id: id, drafts: projection.drafts,
                    editedColumnNames: Set(projection.drafts.keys))
            }
        }
        .onChange(of: documentInspectorModel.creations.order) { _, ids in
            guard isElasticsearchObject else { return }
            rowInsertEditor.retainDraftRows(Set(ids))
        }
        .onChange(of: inspectorContext) { _, context in
            inspectorRegistry.update(context, for: contentID)
        }
        .onDisappear {
            mappingEditor.stop()
            indexInspector.stopReading()
            aliasEditor.stopReading()
            contentRefreshRegistry.remove(for: contentID)
            if isElasticsearchObject, let actions = pendingChangesActions {
                pendingChangesRegistry.update(actions, for: contentID)
            } else { pendingChangesRegistry.remove(for: contentID) }
            inspectorRegistry.remove(for: contentID)
            objectDetailTabRegistry.remove(for: contentID)
            cancelDetailTasks()
        }
    }

    private var availableTabs: [WorkspaceDatabaseObjectDetailTab] {
        WorkspaceDatabaseObjectDetailTab.available(for: selection.kind).filter {
            $0 != .options || model.schemaEditingDescriptor.supportsTableOptions
        }
    }

    private var contentID: WorkspaceContentTabID {
        .databaseObject(selection)
    }

    private var objectDetailTabActions:
        WorkspaceDatabaseObjectDetailTabActions
    {
        WorkspaceDatabaseObjectDetailTabActions(
            availableTabs: availableTabs,
            select: { tab in
                if isElasticsearchObject,
                   (indexInspector.hasChanges || aliasEditor.hasChanges),
                   !indexInspector.isCommitting, !aliasEditor.isCommitting {
                    selectedTab = tab; return
                }
                guard allowDocumentDraftInvalidation() else { return }
                selectedTab = tab
            }
        )
    }

    private func publishContentRefreshActions() {
        contentRefreshRegistry.update(contentRefreshActions, for: contentID)
    }

    private func publishPendingChangesActions() {
        guard let pendingChangesActions else {
            pendingChangesRegistry.remove(for: contentID)
            return
        }
        pendingChangesRegistry.update(pendingChangesActions, for: contentID)
    }

    private func publishDatabaseInspectorContext() {
        inspectorRegistry.update(inspectorContext, for: contentID)
    }

    private var inspectorContext: WorkspaceInspectorContext {
        if isElasticsearchObject && selectedTab == .structure {
            if mappingEditor.selectedRow != nil {
                return .elasticsearchMapping(.init(editor: mappingEditor, workspace: model))
            }
            return .elasticsearchIndex(.init(selection: selection, editor: indexInspector,
                aliasEditor: aliasEditor, workspace: model))
        }
        if selection.kind == .elasticsearchIndex
            || selection.kind == .elasticsearchAlias
            || selection.kind == .elasticsearchDataStream
        {
            if let rowIndex = selectedDataRowIndexes.first,
               selectedDataRowIndexes.count == 1,
               let rowID = draftRowID(forTableRow: rowIndex),
               let child = documentInspectorModel.creations.entries[rowID] {
                return .elasticsearchDocument(WorkspaceElasticsearchDocumentInspectorContext(
                    selection: selection, reference: nil, model: child,
                    beginEditing: {}, updateDraft: { _ in },
                    updateCreationDraft: { id, routing, text in
                        updateDocumentCreationDraft(rowID: rowID, documentID: id, routing: routing, text: text)
                    }, endEditing: {},
                    isReadOnly: documentInspectorModel.creations.isBlocked
                        && !(documentInspectorModel.creations.canCorrectDuplicateID
                            && documentInspectorModel.creations.failedRowID == rowID)
                ))
            }
            guard selectedDocumentReference != nil else {
                return .elasticsearchIndex(.init(selection: selection, editor: indexInspector,
                    aliasEditor: aliasEditor, workspace: model))
            }
            return .elasticsearchDocument(
                WorkspaceElasticsearchDocumentInspectorContext(
                    selection: selection,
                    reference: selectedDocumentReference,
                    model: documentInspectorModel,
                    beginEditing: requestDocumentEditing,
                    updateDraft: updateDocumentDraft,
                    updateCreationDraft: { _, _, _ in },
                    endEditing: endDocumentEditing
                )
            )
        }
        return .database(databaseInspectorContext)
    }

    private var selectedDocumentReference: WorkspaceDocumentReference? {
        guard selectedTab == .data,
              selectedDataRowIndexes.count == 1,
              let rowIndex = selectedDataRowIndexes.first,
              let page = model.selectedObjectDataState.page,
              let row = page.row(at: rowIndex),
              let idColumn = page.columns.first(where: { $0.name == "_id" }),
              let indexColumn = page.columns.first(where: { $0.name == "_index" }),
              case .text(let id) = row.value(at: idColumn.id),
              case .text(let index) = row.value(at: indexColumn.id)
        else { return nil }
        let routing: String?
        if let routingColumn = page.columns.first(where: {
            $0.name == "_routing"
        }), case .text(let value) = row.value(at: routingColumn.id) {
            routing = value
        } else {
            routing = nil
        }
        return WorkspaceDocumentReference(index: index, id: id, routing: routing)
    }

    private func documentReference(
        for target: WorkspaceDatabaseDataCellEditTarget
    ) -> WorkspaceDocumentReference? {
        documentReference(row: target.row, columns: target.columns)
    }

    private func documentReference(
        row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn]
    ) -> WorkspaceDocumentReference? {
        guard
            let idColumn = columns.first(where: { $0.name == "_id" }),
            let indexColumn = columns.first(where: { $0.name == "_index" }),
            case .text(let id) = row.value(at: idColumn.id),
            case .text(let index) = row.value(at: indexColumn.id)
        else {
            return nil
        }
        let routing: String?
        if let routingColumn = columns.first(where: { $0.name == "_routing" }),
           case .text(let value) = row.value(at: routingColumn.id)
        {
            routing = value
        } else {
            routing = nil
        }
        return WorkspaceDocumentReference(index: index, id: id, routing: routing)
    }

    private func elasticsearchIdentityConditions(
        row: WorkspaceDatabaseDataRow,
        columns: [WorkspaceDatabaseDataColumn]
    ) -> [WorkspaceDatabaseDataCellUpdateCondition] {
        ["_id", "_index", "_routing"].compactMap { name in
            guard let column = columns.first(where: { $0.name == name }) else {
                return nil
            }
            let value = row.value(at: column.id)
            guard value != .null else { return nil }
            return WorkspaceDatabaseDataCellUpdateCondition(
                columnName: name,
                value: value
            )
        }
    }

    private var databaseInspectorContext: WorkspaceDatabaseInspectorContext {
        WorkspaceDatabaseInspectorContext(
            selection: selection,
            detailsState: model.selectedObjectDetailsState,
            page: model.selectedObjectDataState.page,
            selectedRowIndexes: selectedDataRowIndexes,
            rowInsertEditor: rowInsertEditor,
            pendingLoadedUpdates: pendingInspectorUpdates,
            schemaInspector: schemaInspectorContext,
            isUpdatingLoadedValue: isSubmittingPendingChanges
                || !model.sessionCapabilities.supportsDataEditing,
            loadDetails: loadInspectorDetails,
            updateLoadedValue: stageInspectorCellUpdates,
            updateDraftValue: updateInspectorDraftValues
        )
    }

    private var pendingChangesActions: WorkspacePendingChangesActions? {
        if aliasEditor.hasChanges {
            return .init(hasChanges: true,
                elasticsearchRequests: aliasEditor.prepared.map { [$0.request] } ?? [],
                canCommit: aliasEditor.canCommit, isCommitting: aliasEditor.isCommitting,
                discard: { aliasEditor.discard() }, preview: {},
                commit: { aliasEditor.requestCommit(workspace: model) })
        }
        if indexInspector.hasChanges {
            return .init(hasChanges: true, elasticsearchRequests: indexInspector.prepared.map { [$0.request] } ?? [],
                canCommit: indexInspector.canCommit, isCommitting: indexInspector.isCommitting,
                discard: { indexInspector.discard() }, preview: {},
                commit: { indexInspector.requestCommit(workspace: model) })
        }
        if mappingEditor.hasChanges {
            return .init(hasChanges: true, elasticsearchRequests: mappingEditor.prepared.map { [$0.request] } ?? [],
                canCommit: mappingEditor.canCommit, isCommitting: mappingEditor.isCommitting,
                discard: { mappingEditor.discard() }, preview: {},
                commit: { mappingEditor.requestEdit(workspace: model) { mappingEditor.commit(workspace: model) } })
        }
        if isElasticsearchObject {
            guard documentInspectorModel.hasChanges else { return nil }
            return WorkspacePendingChangesActions(
                hasChanges: true,
                elasticsearchRequests: documentInspectorModel
                    .preparedChange?.requests ?? [],
                canCommit: documentInspectorModel.canCommit
                    && !isPreparingDocumentDeletion
                    && !isPreparingRowInsert
                    && !isSubmittingPendingChanges,
                isCommitting: documentInspectorModel.isCommitting
                    || isSubmittingPendingChanges,
                discard: discardPendingChanges,
                preview: {},
                commit: requestPendingChangesSubmission
            )
        }
        let schemaPlan = makeSchemaExecutionPlan()
        var statements = pendingRowDeletes.compactMap {
            try? WorkspaceSQLPreviewStatement.make(
                rowDelete: $0.rowDelete,
                databaseType: model.databaseType
            )
        }
        let pendingUpdateChanges = WorkspaceDatabaseDataChangeSet(
            updates: pendingInspectorUpdates.map(\.update),
            inserts: [],
            deletes: []
        )
        statements.append(contentsOf: pendingUpdateChanges.rowUpdates.compactMap {
            try? WorkspaceSQLPreviewStatement.make(
                rowUpdate: $0,
                databaseType: model.databaseType
            )
        })
        if rowInsertEditor.isPresented {
            statements.append(contentsOf: (try? rowInsertEditor.makeInserts().map {
                try WorkspaceSQLPreviewStatement.make(
                    rowInsert: $0,
                    databaseType: model.databaseType
                )
            }) ?? [])
        }
        if let schemaPlan {
            statements.append(
                contentsOf: WorkspaceSQLPreviewStatement.make(
                    schemaExecutionPlan: schemaPlan
                )
            )
        }
        guard hasPendingChanges else { return nil }
        return WorkspacePendingChangesActions(
            hasChanges: true,
            statements: statements,
            isCommitting: isSubmittingPendingChanges,
            discard: discardPendingChanges,
            preview: {},
            commit: {
                requestPendingChangesSubmission(
                    schemaExecutionPlan: schemaPlan
                )
            }
        )
    }

    private var pendingDataCommitMessage: (zhHans: String, en: String) {
        if isElasticsearchObject {
            if documentInspectorModel.isCreating {
                return (
                    "文档会按预览顺序逐篇新增。失败时停止后续创建，已经成功的文档不会回滚。安全锁将在此工作区关闭前保持停用。",
                    "Documents will be created in preview order. A failure stops subsequent creations; successful documents cannot be rolled back. Safety Lock will remain disabled until this workspace closes."
                )
            }
            if documentInspectorModel.isPendingDeletion {
                return (
                    "提交会按预览顺序逐篇删除文档，并检查各自的并发版本。失败时停止后续删除，已成功的删除无法回滚。安全锁将在此工作区关闭前保持停用。",
                    "Documents will be deleted in preview order using their concurrency versions. A failure stops subsequent deletions; successful deletions cannot be rolled back. Safety Lock will remain disabled until this workspace closes."
                )
            }
            if documentInspectorModel.cellChanges.hasChanges {
                return (
                    "提交会按预览顺序逐篇更新已修改字段，并检查各自的并发版本。失败时停止，已成功的更新无法回滚。安全锁将在此工作区关闭前保持停用。",
                    "Changed fields will be updated in preview order using each document's concurrency version. A failure stops the batch; successful updates cannot be rolled back. Safety Lock will remain disabled until this workspace closes."
                )
            }
            return (
                "提交会使用当前文档的并发版本信息替换完整 _source。安全锁将在此工作区关闭前保持停用。",
                "The complete _source will be replaced using the current document concurrency version. Safety Lock will remain disabled until this workspace closes."
            )
        }
        if schemaEditor.hasChanges {
            if model.databaseType == .postgresql {
                return (
                    "数据变更会先在一个事务中提交，随后全部 PostgreSQL 结构变更会在另一个事务中按 SQL 预览顺序执行；任一结构语句失败都会回滚整组结构变更。安全锁将在此工作区关闭前保持停用。",
                    "Data changes commit first in one transaction. All PostgreSQL schema statements then run in preview order in a separate transaction, and any schema failure rolls back the full schema change set. Safety Lock will remain disabled until this workspace closes."
                )
            }
            return (
                "数据变更会先在一个事务中提交，随后字段、索引和表选项变更按 SQL 预览顺序执行。MySQL 结构变更会隐式提交，已成功执行的语句无法由后续失败自动回滚。安全锁将在此工作区关闭前保持停用。",
                "Data changes commit first in one transaction, followed by column, index, and table option changes in SQL preview order. MySQL schema changes commit implicitly, so statements that already succeeded cannot be rolled back automatically if a later statement fails. Safety Lock will remain disabled until this workspace closes."
            )
        }
        if model.databaseType == .postgresql {
            return (
                "提交后，全部待处理的新增、修改和删除会在同一个 PostgreSQL 事务中写入。安全锁将在此工作区关闭前保持停用。",
                "All pending inserts, updates, and deletes will be written in one PostgreSQL transaction. Safety Lock will remain disabled until this workspace closes."
            )
        }
        return (
            "提交后，全部待处理的新增、修改和删除会在同一个 MySQL 事务中写入。安全锁将在此工作区关闭前保持停用。",
            "All pending inserts, updates, and deletes will be written in one MySQL transaction. Safety Lock will remain disabled until this workspace closes."
        )
    }

    private var hasPendingRowChanges: Bool {
        !pendingInspectorUpdates.isEmpty
            || rowInsertEditor.isPresented
            || !pendingRowDeletes.isEmpty
    }

    private var hasPendingChanges: Bool {
        aliasEditor.hasChanges || indexInspector.hasChanges || mappingEditor.hasChanges
            || documentInspectorModel.hasChanges
            || hasPendingRowChanges
            || schemaEditor.hasChanges
    }

    private var isElasticsearchObject: Bool {
        selection.kind == .elasticsearchIndex
            || selection.kind == .elasticsearchAlias
            || selection.kind == .elasticsearchDataStream
    }

    private var synchronousCellEditPreparer: ((
        WorkspaceDatabaseDataCellEditTarget
    ) -> WorkspaceDatabaseDataCellInlineEditContext?)? {
        guard !isElasticsearchObject else { return nil }
        return { target in
            prepareInlineCellEdit(target)
        }
    }

    private var asynchronousCellEditPreparer: ((
        WorkspaceDatabaseDataCellEditTarget
    ) async -> WorkspaceDatabaseDataCellInlineEditContext?)? {
        guard isElasticsearchObject else { return nil }
        return { target in
            await prepareElasticsearchInlineCellEdit(target)
        }
    }

    private var schemaChangeSet: WorkspaceDatabaseSchemaChangeSet {
        WorkspaceDatabaseSchemaChangeSet(
            selection: selection,
            columns: schemaEditor.columns,
            indexes: schemaEditor.indexes,
            tableOptionsChange: schemaEditor.tableOptionsChange
        )
    }

    private func makeSchemaExecutionPlan() -> WorkspaceDatabaseSchemaExecutionPlan? {
        guard schemaEditor.hasChanges else { return nil }
        return try? model.schemaExecutionPlan(for: schemaChangeSet)
    }

    private var schemaInspectorContext: WorkspaceDatabaseSchemaInspectorContext? {
        guard selection.kind == .table else { return nil }
        let availableColumnNames = schemaEditor.columns
            .filter { !$0.isDeleted }
            .map(\.definition.name)
            .filter { !$0.isEmpty }
        switch selectedTab {
        case .structure:
            guard
                let selectedSchemaColumnID,
                let item = schemaEditor.columns.first(where: {
                    $0.id == selectedSchemaColumnID
                })
            else { return nil }
            return WorkspaceDatabaseSchemaInspectorContext(
                item: .column(item),
                descriptor: model.schemaEditingDescriptor,
                availableColumnNames: availableColumnNames,
                schemaChoices: schemaEditor.schemaChoices,
                isPrimaryKey: schemaEditor.isPrimaryKey(columnID: item.id),
                setPrimaryKey: setSchemaColumnPrimaryKey,
                updateColumn: updateSchemaColumn,
                updateIndex: updateSchemaIndex
            )
        case .indexes:
            guard
                let selectedSchemaIndexID,
                let item = schemaEditor.indexes.first(where: {
                    $0.id == selectedSchemaIndexID
                })
            else { return nil }
            return WorkspaceDatabaseSchemaInspectorContext(
                item: .index(item),
                descriptor: model.schemaEditingDescriptor,
                availableColumnNames: availableColumnNames,
                schemaChoices: schemaEditor.schemaChoices,
                isPrimaryKey: false,
                setPrimaryKey: setSchemaColumnPrimaryKey,
                updateColumn: updateSchemaColumn,
                updateIndex: updateSchemaIndex
            )
        case .data, .options, .ddl:
            return nil
        }
    }

    private var pendingDeleteRowIndexes: IndexSet {
        if isElasticsearchObject {
            guard
                let page = model.selectedObjectDataState.page
            else {
                return IndexSet()
            }
            let references = Set(documentInspectorModel.preparedDeletions.map {
                $0.draft.reference
            })
            guard !references.isEmpty else { return [] }
            var indexes = IndexSet()
            for rowIndex in 0..<page.rowCount {
                guard let row = page.row(at: rowIndex) else { continue }
                if let reference = documentReference(row: row, columns: page.columns),
                   references.contains(reference)
                {
                    indexes.insert(rowIndex)
                }
            }
            return indexes
        }
        guard
            !pendingRowDeletes.isEmpty,
            let page = model.selectedObjectDataState.page
        else {
            return IndexSet()
        }
        var indexes = IndexSet()
        for rowIndex in 0..<page.rowCount {
            guard let row = page.row(at: rowIndex) else { continue }
            if pendingRowDeletes.contains(where: {
                $0.applies(to: row, columns: page.columns)
            }) {
                indexes.insert(rowIndex)
            }
        }
        return indexes
    }

    private var canUseRowActions: Bool {
        model.sessionCapabilities.supportsDataEditing
            && selectedTab == .data
            && selection.kind == .table
            && rowInsertPreparationTask == nil
            && rowDeletePreparationTask == nil
            && !model.selectedObjectDataState.isFetching
            && !rowInsertEditor.isSubmitting
            && !isSubmittingPendingChanges
    }

    private var canUseDocumentDeleteActions: Bool {
        isElasticsearchObject
            && !aliasEditor.hasChanges && !aliasEditor.isCommitting
            && !indexInspector.hasChanges && !indexInspector.isCommitting
            && model.sessionCapabilities.supportsDataEditing
            && selectedTab == .data
            && documentDeletionPreparationTask == nil
            && documentDuplicationTask == nil
            && !isPreparingRowInsert
            && !model.selectedObjectDataState.isFetching
            && !isSubmittingPendingChanges
            && !documentInspectorModel.isCommitting
    }

    private var dataRowDeletionAction: (
        @MainActor @Sendable (IndexSet) -> Void
    )? {
        if isElasticsearchObject {
            guard canUseDocumentDeleteActions else { return nil }
            return { rowIndexes in
                beginDeletingDocument(rowIndexes)
            }
        }
        guard canUseRowActions else { return nil }
        return { rowIndexes in
            beginDeletingRows(rowIndexes)
        }
    }

    private var canAddRow: Bool {
        canUseRowActions
    }

    private var canCreateDocument: Bool {
        isElasticsearchObject
            && !aliasEditor.hasChanges && !aliasEditor.isCommitting
            && !indexInspector.hasChanges && !indexInspector.isCommitting
            && model.sessionCapabilities.supportsDataEditing
            && selectedTab == .data
            && model.selectedObjectDataState.page != nil
            && !model.selectedObjectDataState.isFetching
            && (!documentInspectorModel.hasChanges || documentInspectorModel.creations.hasChanges)
            && documentInspectorModel.editingState == .viewing
            && !documentInspectorModel.creations.isBlocked
            && !documentInspectorModel.isCommitting
            && documentDeletionPreparationTask == nil
            && documentDuplicationTask == nil
            && !isSubmittingPendingChanges
    }

    private var canAddRowOrDocument: Bool {
        isElasticsearchObject ? canCreateDocument : canAddRow
    }

    private var dataRowAdditionAction: (@MainActor () -> Void)? {
        if isElasticsearchObject {
            return canCreateDocument ? beginDocumentCreation : nil
        }
        return canAddRow ? beginAddingRow : nil
    }

    private var dataRowDuplicationAction: (
        @MainActor @Sendable (Int) -> Void
    )? {
        if isElasticsearchObject {
            return canCreateDocument ? beginDuplicatingDocument : nil
        }
        return canUseRowActions ? beginDuplicatingRow : nil
    }

    private var canAddSchemaColumn: Bool {
        guard model.schemaEditingDescriptor.canEdit,
              selection.kind == .table,
              !isSubmittingPendingChanges
        else {
            return false
        }
        if case .loaded = model.selectedObjectDetailsState { return true }
        return false
    }

    private var canAddSchemaIndex: Bool {
        guard canAddSchemaColumn else { return false }
        if case .loaded = model.selectedObjectIndexesState { return true }
        return false
    }

    private var addRowDisabledReason: String? {
        guard !canAddRowOrDocument else { return nil }
        if isElasticsearchObject {
            if documentInspectorModel.hasChanges {
                return AppCopy.current.text(
                    "请先提交或放弃当前文档更改。",
                    "Commit or discard the current document changes first."
                )
            }
            if isSubmittingPendingChanges || documentInspectorModel.isCommitting {
                return AppCopy.current.text(
                    "正在提交更改，请稍候。",
                    "Changes are being committed. Please wait."
                )
            }
            if isPreparingDocumentDuplication {
                return AppCopy.current.text(
                    "正在准备复制文档，请稍候。",
                    "The document duplicate is being prepared. Please wait."
                )
            }
            if model.selectedObjectDataState.isFetching {
                return AppCopy.current.text(
                    "文档加载完成后可以新增文档。",
                    "A document can be added after loading finishes."
                )
            }
            return AppCopy.current.text(
                "当前状态无法新增文档。",
                "A document cannot be added in the current state."
            )
        }
        if isSubmittingPendingChanges || rowInsertEditor.isSubmitting {
            return AppCopy.current.text(
                "正在提交更改，请稍候。",
                "Changes are being committed. Please wait."
            )
        }
        if rowInsertPreparationTask != nil || rowDeletePreparationTask != nil {
            return AppCopy.current.text(
                "正在准备数据操作，请稍候。",
                "A data operation is being prepared. Please wait."
            )
        }
        if model.selectedObjectDataState.isFetching {
            return AppCopy.current.text(
                "数据加载完成后可以新增行。",
                "Rows can be added after the data finishes loading."
            )
        }
        return AppCopy.current.text(
            "当前状态无法新增行。",
            "A row cannot be added in the current state."
        )
    }

    private var dataRowCommandActions: WorkspaceDatabaseDataRowCommandActions? {
        guard selectedTab == .data else { return nil }
        let actionRowIndexes = selectedDataRowIndexes.isEmpty
            ? lastDraftTableRowIndex.map(IndexSet.init(integer:)) ?? IndexSet()
            : selectedDataRowIndexes
        let actionRowIndex = actionRowIndexes.count == 1
            ? actionRowIndexes.first
            : nil
        if isElasticsearchObject {
            return WorkspaceDatabaseDataRowCommandActions(
                selectedRowIndexes: actionRowIndexes,
                canAddRow: canCreateDocument,
                canDuplicateRow: actionRowIndex.map(canDuplicateDocument) == true,
                canDeleteRow: canDeleteDocument(actionRowIndexes),
                kind: .elasticsearchDocument,
                addRow: beginDocumentCreation,
                duplicateRow: beginDuplicatingDocument,
                deleteRows: beginDeletingDocument
            )
        }
        guard selection.kind == .table else { return nil }
        return WorkspaceDatabaseDataRowCommandActions(
            selectedRowIndexes: actionRowIndexes,
            canAddRow: canAddRow,
            canDuplicateRow: actionRowIndex.map(canDuplicateRow) == true,
            canDeleteRow: canDeleteRows(actionRowIndexes),
            addRow: beginAddingRow,
            duplicateRow: beginDuplicatingRow,
            deleteRows: beginDeletingRows
        )
    }

    private var schemaRowCommandActions:
        WorkspaceDatabaseSchemaRowCommandActions?
    {
        if isElasticsearchObject && selectedTab == .structure {
            return .init(kind: .column, selectedID: mappingEditor.selectedID,
                canAdd: mappingEditor.canAddFields,
                canDuplicate: false, canDelete: mappingEditor.selectedRow?.isNew == true && !mappingEditor.isCommitting,
                add: addMappingField, duplicate: { _ in }, delete: { mappingEditor.removeDraft($0, workspace: model) })
        }
        guard selection.kind == .table else { return nil }
        switch selectedTab {
        case .structure:
            let selectedItem = selectedSchemaColumnID.flatMap { id in
                schemaEditor.columns.first(where: { $0.id == id })
            }
            return WorkspaceDatabaseSchemaRowCommandActions(
                kind: .column,
                selectedID: selectedSchemaColumnID,
                canAdd: canAddSchemaColumn,
                canDuplicate: canAddSchemaColumn
                    && selectedItem?.isDeleted == false,
                canDelete: canAddSchemaColumn
                    && selectedItem?.isDeleted == false,
                add: addSchemaColumn,
                duplicate: duplicateSchemaColumn,
                delete: deleteSchemaColumn
            )
        case .indexes:
            let selectedItem = selectedSchemaIndexID.flatMap { id in
                schemaEditor.indexes.first(where: { $0.id == id })
            }
            return WorkspaceDatabaseSchemaRowCommandActions(
                kind: .index,
                selectedID: selectedSchemaIndexID,
                canAdd: canAddSchemaIndex,
                canDuplicate: canAddSchemaIndex
                    && selectedItem?.isDeleted == false,
                canDelete: canAddSchemaIndex
                    && selectedItem?.isDeleted == false,
                add: addSchemaIndex,
                duplicate: duplicateSchemaIndex,
                delete: deleteSchemaIndex
            )
        case .data, .options, .ddl:
            return nil
        }
    }

    private func prepareInlineCellEdit(
        _ target: WorkspaceDatabaseDataCellEditTarget
    ) -> WorkspaceDatabaseDataCellInlineEditContext? {
        guard
            model.sessionCapabilities.supportsDataEditing,
            selectedTab == .data,
            selection.kind == .table,
            !isSubmittingPendingChanges,
            let page = model.selectedObjectDataState.page,
            let row = page.row(at: target.rowIndex),
            !pendingRowDeletes.contains(where: {
                $0.applies(to: row, columns: page.columns)
            }),
            case let .loaded(details) = model.selectedObjectDetailsState
        else {
            return nil
        }
        do {
            return try WorkspaceLoadedDataCellEditing.inlineContext(
                selection: selection,
                target: target,
                details: details,
                pendingUpdates: pendingInspectorUpdates
            )
        } catch {
            presentCellEditError(error.localizedDescription)
            return nil
        }
    }

    private func prepareElasticsearchInlineCellEdit(
        _ target: WorkspaceDatabaseDataCellEditTarget
    ) async -> WorkspaceDatabaseDataCellInlineEditContext? {
        guard !aliasEditor.hasChanges, !aliasEditor.isCommitting,
              !indexInspector.hasChanges, !indexInspector.isCommitting else {
            showsDocumentDraftNavigationBlocked = true; return nil
        }
        let editingRevision = documentCellEditingLifetime.revision
        guard
            isElasticsearchObject,
            model.sessionCapabilities.supportsDataEditing,
            selectedTab == .data,
            !isSubmittingPendingChanges,
            documentDuplicationTask == nil,
            documentDeletionPreparationTask == nil,
            let column = target.column,
            WorkspaceElasticsearchDocumentCellEditor.canEdit(
                fieldName: column.name
            ),
            let reference = documentReference(for: target)
        else {
            return nil
        }
        if documentInspectorModel.isPendingDeletion
            || documentInspectorModel.isCreating
            || documentInspectorModel.cellChanges.isBlocked {
            showsDocumentDraftNavigationBlocked = true
            return nil
        }
        if documentInspectorModel.blocksDocumentSelectionChanges,
           documentInspectorModel.loadedSnapshot?.reference != reference
        {
            showsDocumentDraftNavigationBlocked = true
            return nil
        }

        selectedDataRowIndexes = IndexSet(integer: target.rowIndex)
        if documentInspectorModel.loadedSnapshot?.reference != reference {
            await documentInspectorModel.load(reference: reference) { reference in
                try await model.fetchDocument(reference)
            }
        }
        guard !Task.isCancelled else { return nil }
        if case let .failed(failedReference, message) =
            documentInspectorModel.state,
            failedReference == reference
        {
            presentCellEditError(message)
            return nil
        }
        guard
            documentInspectorModel.loadedSnapshot?.reference == reference
        else {
            return nil
        }

        do {
            if documentInspectorModel.isEditing {
                showsDocumentDraftNavigationBlocked = true
                return nil
            }
            guard let snapshot = documentInspectorModel.loadedSnapshot,
                  !snapshot.isTruncated,
                  snapshot.sequenceNumber != nil,
                  snapshot.primaryTerm != nil
            else { throw WorkspaceDocumentEditingError.missingConcurrencyMetadata }
            let initialValue = try await documentInspectorModel.cellChanges.initialValue(
                snapshot: snapshot,
                fieldName: column.name
            )
            try Task.checkCancellation()
            guard documentCellEditingLifetime.revision == editingRevision else { return nil }
            documentInlineEditSnapshot = snapshot
            return WorkspaceDatabaseDataCellInlineEditContext(
                rowIndex: target.rowIndex,
                dataColumnIndex: target.dataColumnIndex,
                columnName: column.name,
                initialText: initialValue.text,
                initialMutation: initialValue.mutation,
                placeholderText: initialValue.mutation == .null ? "NULL" : nil,
                editingLifetime: documentCellEditingLifetime,
                editingRevision: editingRevision
            )
        } catch is CancellationError {
            return nil
        } catch {
            presentCellEditError(error.localizedDescription)
            return nil
        }
    }

    private func updateInlineCellEdit(
        _ context: WorkspaceDatabaseDataCellInlineEditContext,
        mutation: WorkspaceDatabaseInspectorMutation
    ) {
        if isElasticsearchObject {
            stageElasticsearchCellUpdate(context, mutation: mutation)
            return
        }
        stageInspectorCellUpdates(
            rowIndexes: IndexSet(integer: context.rowIndex),
            dataColumnIndex: context.dataColumnIndex,
            mutation: mutation
        )
    }

    private func stageElasticsearchCellUpdate(
        _ context: WorkspaceDatabaseDataCellInlineEditContext,
        mutation: WorkspaceDatabaseInspectorMutation
    ) {
        guard
            !isSubmittingPendingChanges,
            let page = model.selectedObjectDataState.page,
            let row = page.row(at: context.rowIndex),
            let reference = documentReference(row: row, columns: page.columns),
            let snapshot = documentInspectorModel.cellChanges.entries[reference]?.snapshot
                ?? documentInlineEditSnapshot,
            snapshot.reference == reference,
            let column = page.columns.first(where: {
                $0.id == context.dataColumnIndex
            }),
            WorkspaceElasticsearchDocumentCellEditor.canEdit(
                fieldName: column.name
            )
        else {
            return
        }
        if documentInspectorModel.isEditing || documentInspectorModel.isCreating
            || documentInspectorModel.isPendingDeletion || documentInspectorModel.cellChanges.isBlocked {
            showsDocumentDraftNavigationBlocked = true
            return
        }

        let originalValue = row.value(at: context.dataColumnIndex)
        let newValue: WorkspaceDatabaseDataCell
        switch mutation {
        case let .value(text):
            newValue = WorkspaceElasticsearchDocumentCellEditor.cellValue(
                forInput: text
            )
        case .null:
            newValue = .null
        case .useDefault:
            return
        }
        let identity = elasticsearchIdentityConditions(
            row: row,
            columns: page.columns
        )
        guard !identity.isEmpty else { return }
        let update = WorkspaceDatabaseDataCellUpdate(
            selection: selection,
            columnName: column.name,
            originalValue: originalValue,
            newValue: newValue,
            primaryKey: identity
        )
        var replacementUpdates = pendingInspectorUpdates.filter { !$0.matches(update) }
        if newValue != originalValue {
            replacementUpdates.append(
                WorkspaceDatabaseInspectorPendingUpdate(update: update)
            )
        }

        var edits: [String: WorkspaceDatabaseDataCell] = [:]
        for pending in replacementUpdates
        where pending.applies(to: row, columns: page.columns) {
            edits[pending.update.columnName] = pending.update.newValue
        }
        do {
            try documentInspectorModel.stageCellChanges(snapshot: snapshot, edits: edits) { draft in
                try await model.prepareDocumentPartialUpdate(draft)
            }
            pendingInspectorUpdates = replacementUpdates
        } catch {
            presentCellEditError(error.localizedDescription)
        }
    }

    private var loadID: String {
        switch selectedTab {
        case .data:
            "\(selection.id):data:\(dataOffset):\(dataLimit):"
                + "\(dataSort):\(dataFilterRevision):\(reloadRequest)"
        case .structure, .options, .ddl:
            "\(selection.id):details:\(reloadRequest)"
        case .indexes:
            "\(selection.id):indexes:\(reloadRequest)"
        }
    }

    private var isDataWorkActive: Bool {
        model.selectedObjectDataState.isFetching
            || model.selectedObjectDataCountState == .loading
            || isPreparingDocumentDeletion
            || isPreparingDocumentDuplication
            || (isElasticsearchObject && isPreparingRowInsert)
            || (isElasticsearchObject && isSubmittingPendingChanges)
    }

    private var isStoppingData: Bool {
        selectedTab == .data && (model.selectedObjectDataState.isFetching
            || (isElasticsearchObject && isPreparingRowInsert))
    }

    private var refreshLabel: String {
        switch selectedTab {
        case .data:
            AppCopy.current.text("刷新数据", "Refresh Data")
        case .indexes:
            AppCopy.current.text("刷新索引", "Refresh Indexes")
        case .structure, .options, .ddl:
            AppCopy.current.text("刷新对象详情", "Refresh Object Details")
        }
    }

    private func retry() {
        guard allowDocumentDraftInvalidation() else { return }
        if isElasticsearchObject, selectedTab == .structure {
            mappingEditor.load(target: mappingEditor.snapshot?.target ?? .init(resource: selection.objectName, kind: selection.kind), workspace: model)
        }
        showsRefreshCompletion = false
        reloadRequest += 1
        pendingRefreshRequest = reloadRequest
    }

    private var contentRefreshActions: WorkspaceContentRefreshActions {
        if isStoppingData {
            WorkspaceContentRefreshActions(
                title: AppCopy.current.text(
                    "停止获取数据",
                    "Stop Fetching Data"
                ),
                isStopping: true,
                didComplete: false,
                perform: stopDataFetching
            )
        } else {
            WorkspaceContentRefreshActions(
                title: refreshLabel,
                isStopping: false,
                didComplete: showsRefreshCompletion,
                perform: retry
            )
        }
    }

    private func loadSelectedContent() async {
        let refreshRequest = pendingRefreshRequest
        let isRefresh = refreshRequest != nil

        if isRefresh {
            async let objectsWereRefreshed = model.refreshObjects(
                in: selection.databaseName
            )
            await loadSelectedTab(force: true)
            let didRefreshObjects = await objectsWereRefreshed
            finishRefresh(
                request: refreshRequest,
                didRefreshObjects: didRefreshObjects
            )
        } else {
            await loadSelectedTab(force: false)
        }
    }

    private func loadSelectedContentIfNeeded() async {
        if isElasticsearchObject, model.elasticsearchMutationRevision > 0 {
            // Console writes invalidate server caches, but must not replace a staged grid.
            guard !hasPendingChanges else { return }
        }
        if synchronizedDocumentPageLoadID == loadID {
            synchronizedDocumentPageLoadID = nil
            return
        }
        await loadSelectedContent()
    }

    private func synchronizeDocumentPageOffset() {
        guard isElasticsearchObject,
              case .loaded(let page) = model.selectedObjectDataState,
              page.limit == dataLimit,
              page.sort == dataSort,
              page.filter == currentAppliedDataFilter,
              page.offset != dataOffset
        else { return }
        dataOffset = page.offset
        // The completed refresh already loaded this range; do not issue a second fetch.
        synchronizedDocumentPageLoadID = loadID
    }

    private func loadSelectedTab(force: Bool) async {
        switch selectedTab {
        case .data:
            if !didResolveDefaultDataSort {
                await model.loadDetails(for: selection, force: force)
                guard !Task.isCancelled else { return }
                didResolveDefaultDataSort = true

                if selection.kind == .table,
                   dataSort == .none,
                   case let .loaded(details) = model.selectedObjectDetailsState
                {
                    let defaultSort = WorkspaceDatabaseDataSort.defaultForTable(
                        columns: details.columns
                    )
                    if defaultSort != .none {
                        dataSort = defaultSort
                        return
                    }
                }

                await model.loadData(
                    for: selection,
                    offset: dataOffset,
                    limit: dataLimit,
                    sort: dataSort,
                    filter: currentAppliedDataFilter,
                    force: force
                )
                return
            }

            async let details: Void = model.loadDetails(
                for: selection,
                force: force
            )
            await model.loadData(
                for: selection,
                offset: dataOffset,
                limit: dataLimit,
                sort: dataSort,
                filter: currentAppliedDataFilter,
                force: force
            )
            await details
        case .structure:
            async let indexes: Void = model.loadIndexes(
                for: selection,
                force: force
            )
            await model.loadDetails(for: selection, force: force)
            await indexes
        case .options, .ddl:
            await model.loadDetails(for: selection, force: force)
        case .indexes:
            async let details: Void = model.loadDetails(
                for: selection,
                force: force
            )
            await model.loadIndexes(for: selection, force: force)
            await details
        }
    }

    private func finishRefresh(
        request: Int?,
        didRefreshObjects: Bool
    ) {
        guard let request, pendingRefreshRequest == request else { return }
        pendingRefreshRequest = nil
        guard
            !Task.isCancelled,
            didRefreshObjects,
            selectedContentLoadedSuccessfully
        else {
            return
        }
        showsRefreshCompletion = true
        refreshCompletionRequest += 1
    }

    private var selectedContentLoadedSuccessfully: Bool {
        switch selectedTab {
        case .data:
            if case .loaded = model.selectedObjectDataState {
                return true
            }
            return false
        case .indexes:
            if case .loaded = model.selectedObjectIndexesState {
                return true
            }
            return false
        case .structure, .options, .ddl:
            if case .loaded = model.selectedObjectDetailsState {
                return true
            }
            return false
        }
    }

    private var dataFilterPresentationActions:
        WorkspaceDatabaseDataFilterPresentationActions?
    {
        guard
            selectedTab == .data,
            dataFilterDetailsTask == nil || isCurrentDataFilterPresented
        else {
            return nil
        }
        return WorkspaceDatabaseDataFilterPresentationActions(
            toggle: toggleDataFilter
        )
    }

    private func previousDataPage() {
        guard allowDocumentDraftInvalidation() else { return }
        dataOffset = max(0, dataOffset - dataLimit)
    }

    private func nextDataPage() {
        guard allowDocumentDraftInvalidation() else { return }
        dataOffset += dataLimit
    }

    private func loadDataRange(limit: Int, offset: Int) {
        guard allowDocumentDraftInvalidation() else { return }
        dataLimit = limit
        dataOffset = offset
    }

    private func sortData(_ sort: WorkspaceDatabaseDataSort) {
        guard allowDocumentDraftInvalidation() else { return }
        guard dataSort != sort else { return }
        dataSort = sort
        dataOffset = 0
    }

    private func toggleDataFilter() {
        guard allowDocumentDraftInvalidation() else { return }
        if isCurrentDataFilterPresented {
            dismissDataFilter()
        } else {
            presentDataFilter()
        }
    }

    private func presentDataFilter() {
        if let defaultDataFilterCondition {
            presentPreparedDataFilter(defaultCondition: defaultDataFilterCondition)
            return
        }

        guard dataFilterDetailsTask == nil else { return }
        dataFilterDetailsTask = Task { @MainActor in
            defer { dataFilterDetailsTask = nil }
            await model.loadDetails(for: selection)
            guard !Task.isCancelled, selectedTab == .data else { return }
            presentPreparedDataFilter(defaultCondition: defaultDataFilterCondition)
        }
    }

    private func loadFilterColumns() {
        guard dataFilterDetailsTask == nil else { return }
        dataFilterDetailsTask = Task { @MainActor in
            defer { dataFilterDetailsTask = nil }
            await model.loadDetails(for: selection)
        }
    }

    private func dismissDataFilter() {
        cancelDataFilterDetailsTask()
        dataFilterEditor.dismiss(appliedFilter: currentAppliedDataFilter)
    }

    private var defaultDataFilterCondition: WorkspaceDatabaseDataFilterCondition? {
        guard case let .loaded(details) = model.selectedObjectDetailsState else {
            return nil
        }
        if let fields = details.documentMappingFields {
            for field in fields where field.dataFilterKind != nil {
                guard let column = details.columns.first(
                    where: { $0.name == field.path }
                ) else { continue }
                return column.defaultDataFilterCondition(mappingField: field)
            }
            return nil
        }
        return details.columns.first?.defaultDataFilterCondition
    }

    private func presentPreparedDataFilter(
        defaultCondition: WorkspaceDatabaseDataFilterCondition?
    ) {
        dataFilterEditor.present(
            appliedFilter: currentAppliedDataFilter,
            defaultCondition: defaultCondition
        )
    }

    private func cancelDataFilterDetailsTask() {
        dataFilterDetailsTask?.cancel()
        dataFilterDetailsTask = nil
    }

    private func applyDataFilter() {
        guard allowDocumentDraftInvalidation() else { return }
        guard dataFilterEditor.draft.isValid else { return }
        setAppliedDataFilter(dataFilterEditor.draft)
    }

    private func setAppliedDataFilter(
        _ filter: WorkspaceDatabaseDataFilter
    ) {
        if dataFilterSelectionID != selection.id {
            resetDataState(for: selection.id)
        }
        guard appliedDataFilter != filter else { return }
        appliedDataFilter = filter
        dataOffset = 0
        dataFilterRevision += 1
    }

    private func clearDataFilter() {
        guard allowDocumentDraftInvalidation() else { return }
        guard currentAppliedDataFilter.isActive else { return }
        appliedDataFilter = .empty
        dataFilterEditor.draft = .empty
        dataOffset = 0
        dataFilterRevision += 1
    }

    private var currentAppliedDataFilter: WorkspaceDatabaseDataFilter {
        dataFilterSelectionID == selection.id ? appliedDataFilter : .empty
    }

    private var isCurrentDataFilterPresented: Bool {
        dataFilterSelectionID == selection.id && dataFilterEditor.isPresented
    }

    private func resetDataState(for selectionID: String) {
        synchronizedDocumentPageLoadID = nil
        cancelDataFilterDetailsTask()
        cancelDocumentDuplication()
        cancelDocumentDeletionPreparation()
        dataFilterSelectionID = selectionID
        appliedDataFilter = .empty
        dataFilterEditor.resetForSelectionChange()
        dataFilterRevision &+= 1
        dataOffset = 0
        dataSort = .none
        didResolveDefaultDataSort = false
        selectedDataRowIndexes = []
    }

    private func stopDataFetching() {
        if isElasticsearchObject, isPreparingRowInsert {
            cancelDocumentPaste()
            return
        }
        Task {
            await model.stopDataWork(for: selection, reason: .userStopped)
        }
    }

    private func stageInspectorCellUpdates(
        rowIndexes: IndexSet,
        dataColumnIndex: Int,
        mutation: WorkspaceDatabaseInspectorMutation
    ) {
        guard
            model.sessionCapabilities.supportsDataEditing,
            selectedTab == .data,
            !isSubmittingPendingChanges,
            let page = model.selectedObjectDataState.page,
            page.columns.indices.contains(dataColumnIndex),
            case let .loaded(details) = model.selectedObjectDetailsState
        else {
            return
        }
        var nextPendingUpdates = pendingInspectorUpdates
        var firstErrorMessage: String?

        for rowIndex in rowIndexes {
            guard let row = page.row(at: rowIndex) else { continue }
            guard !pendingRowDeletes.contains(where: {
                $0.applies(to: row, columns: page.columns)
            }) else {
                continue
            }
            let target = WorkspaceDatabaseDataCellEditTarget(
                rowIndex: rowIndex,
                dataColumnIndex: dataColumnIndex,
                columns: page.columns,
                row: row
            )
            do {
                let request = try WorkspaceDatabaseDataCellEditRequest.make(
                    selection: selection,
                    target: target,
                    details: details
                )
                let update = try WorkspaceLoadedDataCellEditing.update(
                    request: request,
                    mutation: mutation
                )
                let pendingUpdate = WorkspaceDatabaseInspectorPendingUpdate(
                    update: update
                )
                if let index = nextPendingUpdates.firstIndex(where: {
                    $0.matches(update)
                }) {
                    nextPendingUpdates[index] = pendingUpdate
                } else {
                    nextPendingUpdates.append(pendingUpdate)
                }
            } catch WorkspaceDatabaseDataCellEditError.unchangedValue {
                nextPendingUpdates.removeAll {
                    $0.applies(
                        to: row,
                        columns: page.columns,
                        dataColumnIndex: dataColumnIndex
                    )
                }
            } catch {
                if firstErrorMessage == nil {
                    firstErrorMessage = error.localizedDescription
                }
            }
        }

        pendingInspectorUpdates = nextPendingUpdates
        if let firstErrorMessage {
            presentCellEditError(firstErrorMessage)
        }
    }

    private func loadInspectorDetails() {
        loadFilterColumns()
    }

    private func updateInspectorDraftValues(
        rowIDs: [UUID],
        columnName: String,
        mutation: WorkspaceDatabaseInspectorMutation
    ) {
        guard
            let column = rowInsertEditor.column(named: columnName),
            !rowInsertEditor.isSubmitting
        else {
            return
        }
        var editor = rowInsertEditor
        for rowID in rowIDs {
            guard var draft = editor.draft(
                rowID: rowID,
                for: columnName
            ) else {
                continue
            }
            switch mutation {
            case let .value(value):
                draft.mode = .value
                draft.text = value
            case .null:
                guard column.column.isNullable else { return }
                draft.mode = .null
            case .useDefault:
                guard column.canUseDefault else { return }
                draft.mode = .useDefault
            }
            editor.update(
                rowID: rowID,
                columnName: columnName,
                draft: draft
            )
        }
        rowInsertEditor = editor
    }

    private func beginAddingRow() {
        guard canAddRow else { return }
        if rowInsertEditor.isPresented {
            rowInsertEditor.appendRow()
            selectLastDraftRow()
            return
        }
        beginPreparingRowInsert(duplicating: nil)
    }

    private func beginAddingRowOrDocument() {
        if isElasticsearchObject {
            beginDocumentCreation()
        } else {
            beginAddingRow()
        }
    }

    private func beginDuplicatingRow(_ rowIndex: Int) {
        guard canDuplicateRow(rowIndex) else { return }
        if let draftRowID = draftRowID(forTableRow: rowIndex) {
            rowInsertEditor.duplicateRow(id: draftRowID)
            selectLastDraftRow()
            return
        }
        if rowInsertEditor.isPresented,
           let page = model.selectedObjectDataState.page,
           let sourceRow = page.row(at: rowIndex)
        {
            do {
                try rowInsertEditor.appendRow(
                    duplicating: sourceRow,
                    pageColumns: page.columns
                )
                selectLastDraftRow()
            } catch {
                presentRowInsertError(error.localizedDescription)
            }
            return
        }
        beginPreparingRowInsert(duplicating: rowIndex)
    }

    private func beginPastingRows(
        _ content: WorkspaceGridPasteboardContent,
        targetColumnNames: [String],
        replacingDraftRowID: UUID?
    ) {
        if isElasticsearchObject {
            guard canCreateDocument else { return }
            pendingDocumentDuplicationRowIndex = nil
            pendingDocumentPaste = (content, targetColumnNames, replacingDraftRowID)
            if model.safetyLock.isEnabled {
                showsDisableSafetyLockForDocumentCreation = true
            } else {
                startPendingDocumentCreation()
            }
            return
        }
        guard
            canAddRow,
            let page = model.selectedObjectDataState.page
        else {
            return
        }
        let preparationID = UUID()
        rowInsertPreparationID = preparationID
        isPreparingRowInsert = true
        rowInsertPreparationTask = Task { @MainActor in
            defer {
                if rowInsertPreparationID == preparationID {
                    isPreparingRowInsert = false
                    rowInsertPreparationTask = nil
                    rowInsertPreparationID = nil
                }
            }
            do {
                let request: WorkspaceDatabaseDataRowInsertRequest
                if let existingRequest = rowInsertEditor.request {
                    request = existingRequest
                } else {
                    await model.loadDetails(for: selection)
                    guard
                        !Task.isCancelled,
                        rowInsertPreparationID == preparationID,
                        selectedTab == .data,
                        model.selectedObjectDataState.page?.revision
                            == page.revision,
                        case let .loaded(details) =
                            model.selectedObjectDetailsState
                    else {
                        if !Task.isCancelled {
                            throw WorkspaceDatabaseDataRowInsertError
                                .editingContextChanged
                        }
                        return
                    }
                    request = try WorkspaceDatabaseDataRowInsertRequest.make(
                        selection: selection,
                        details: details
                    )
                }

                let pastedRows = try await WorkspaceGridPasteParser.shared
                    .makeDraftRows(
                        from: content,
                        targetColumnNames: targetColumnNames,
                        request: request
                    )
                guard
                    !Task.isCancelled,
                    rowInsertPreparationID == preparationID,
                    selectedTab == .data,
                    model.selectedObjectDataState.page?.revision
                        == page.revision
                else {
                    return
                }
                if rowInsertEditor.isPresented {
                    guard rowInsertEditor.request?.id == request.id else {
                        throw WorkspaceDatabaseDataRowInsertError
                            .editingContextChanged
                    }
                    try rowInsertEditor.applyPastedRows(
                        pastedRows,
                        replacingRowID: replacingDraftRowID
                    )
                } else {
                    try rowInsertEditor.present(
                        request,
                        pastedRows: pastedRows
                    )
                }
                if let replacingDraftRowID,
                   let draftIndex = rowInsertEditor.rowIndex(
                       id: replacingDraftRowID
                   )
                {
                    let firstRow = page.rowCount + draftIndex
                    selectedDataRowIndexes = IndexSet(
                        integersIn: firstRow..<(firstRow + pastedRows.count)
                    )
                } else {
                    let firstRow = page.rowCount
                        + rowInsertEditor.rowCount
                        - pastedRows.count
                    selectedDataRowIndexes = IndexSet(
                        integersIn: firstRow..<(firstRow + pastedRows.count)
                    )
                }
            } catch is CancellationError {
                // A newer table action or closed view owns the state now.
            } catch {
                presentRowInsertError(error.localizedDescription)
            }
        }
    }

    private func beginPreparingRowInsert(duplicating rowIndex: Int?) {
        guard
            canUseRowActions,
            let page = model.selectedObjectDataState.page,
            rowIndex.flatMap(page.row(at:)) != nil || rowIndex == nil
        else {
            return
        }
        let sourceRow = rowIndex.flatMap(page.row(at:))
        let preparationID = UUID()
        rowInsertPreparationID = preparationID
        isPreparingRowInsert = true
        rowInsertPreparationTask = Task { @MainActor in
            defer {
                if rowInsertPreparationID == preparationID {
                    isPreparingRowInsert = false
                    rowInsertPreparationTask = nil
                    rowInsertPreparationID = nil
                }
            }
            await model.loadDetails(for: selection)
            guard
                !Task.isCancelled,
                rowInsertPreparationID == preparationID,
                selectedTab == .data,
                model.selectedObjectDataState.page?.revision == page.revision,
                case let .loaded(details) = model.selectedObjectDetailsState
            else {
                if !Task.isCancelled {
                    presentRowInsertError(
                        AppCopy.current.text(
                            "无法读取表结构，请重试。",
                            "Unable to load the table structure. Try again."
                        )
                    )
                }
                return
            }
            do {
                let request = try WorkspaceDatabaseDataRowInsertRequest.make(
                    selection: selection,
                    details: details
                )
                if let sourceRow {
                    try rowInsertEditor.present(
                        request,
                        duplicating: sourceRow,
                        pageColumns: page.columns
                    )
                } else {
                    rowInsertEditor.present(request)
                }
                selectedDataRowIndexes = IndexSet(integer: page.rowCount)
            } catch {
                presentRowInsertError(error.localizedDescription)
            }
        }
    }

    private func canDeleteDocument(_ rowIndexes: IndexSet) -> Bool {
        guard
            canUseDocumentDeleteActions,
            !rowIndexes.isEmpty,
            let page = model.selectedObjectDataState.page
        else {
            return false
        }
        if documentInspectorModel.isCreating {
            return rowIndexes.allSatisfy { draftRowID(forTableRow: $0) != nil }
        }
        guard !documentInspectorModel.hasChanges || documentInspectorModel.isPendingDeletion
        else { return false }
        return rowIndexes.allSatisfy { page.row(at: $0) != nil }
    }

    private func beginDeletingDocument(_ rowIndexes: IndexSet) {
        guard
            !rowIndexes.isEmpty,
            let rowIndex = rowIndexes.first
        else {
            return
        }
        if draftRowID(forTableRow: rowIndex) != nil,
           documentInspectorModel.isCreating,
           let page = model.selectedObjectDataState.page
        {
            guard rowIndexes.allSatisfy({ draftRowID(forTableRow: $0) != nil }) else {
                showsDocumentDraftNavigationBlocked = true
                return
            }
            let ids = Set(rowIndexes.compactMap(draftRowID(forTableRow:)))
            documentInspectorModel.creations.remove(rowIDs: ids)
            for id in ids { rowInsertEditor.removeRow(id: id) }
            if !rowInsertEditor.isPresented { documentInspectorModel.discardChanges() }
            selectNearestActiveDataRow(startingAt: rowIndex, page: page)
            return
        }
        guard canUseDocumentDeleteActions else { return }
        guard !documentInspectorModel.hasChanges || documentInspectorModel.isPendingDeletion else {
            showsDocumentDraftNavigationBlocked = true
            return
        }
        let newRows = rowIndexes.subtracting(pendingDeleteRowIndexes)
        if newRows.isEmpty {
            undoPendingDocumentDeletions(at: rowIndexes)
            return
        }
        pendingDocumentDeletionRows = newRows
        if model.safetyLock.isEnabled {
            showsDisableSafetyLockForDocumentDelete = true
        } else {
            startPendingDocumentDeletion()
        }
    }

    private func startPendingDocumentDeletion() {
        guard
            canUseDocumentDeleteActions,
            !pendingDocumentDeletionRows.isEmpty,
            let page = model.selectedObjectDataState.page,
            !documentInspectorModel.hasChanges || documentInspectorModel.isPendingDeletion,
            documentDeletionPreparationTask == nil
        else {
            pendingDocumentDeletionRows = []
            return
        }

        let preparationID = UUID()
        let pageRevision = page.revision
        let rowIndexes = pendingDocumentDeletionRows
        let previousChange = documentInspectorModel.preparedChange
        documentDeletionPreparationID = preparationID
        isPreparingDocumentDeletion = true
        selectedDataRowIndexes = rowIndexes
        documentDeletionPreparationTask = Task { @MainActor in
            defer {
                if documentDeletionPreparationID == preparationID {
                    documentDeletionPreparationTask = nil
                    documentDeletionPreparationID = nil
                    isPreparingDocumentDeletion = false
                    pendingDocumentDeletionRows = []
                }
            }
            do {
                var deletions: [WorkspacePreparedDocumentDeletion] = []
                for rowIndex in rowIndexes {
                    try Task.checkCancellation()
                    guard let row = page.row(at: rowIndex),
                          let reference = documentReference(row: row, columns: page.columns)
                    else { throw WorkspaceDocumentEditingError.unavailable }
                    let snapshot = try await model.fetchDocument(reference)
                    try Task.checkCancellation()
                    guard let sequenceNumber = snapshot.sequenceNumber,
                          let primaryTerm = snapshot.primaryTerm
                    else {
                        throw WorkspaceDocumentEditingError.missingConcurrencyMetadata
                    }
                    let draft = WorkspaceDocumentDeletionDraft(
                        reference: snapshot.reference,
                        sequenceNumber: sequenceNumber,
                        primaryTerm: primaryTerm
                    )
                    deletions.append(try await model.prepareDocumentDeletion(draft))
                }
                try Task.checkCancellation()
                guard
                    documentDeletionPreparationID == preparationID,
                    selectedTab == .data,
                    model.selectedObjectDataState.page?.revision == pageRevision,
                    documentInspectorModel.preparedChange == previousChange,
                    !documentInspectorModel.isCommitting
                else { return }
                try documentInspectorModel.stageDeletions(deletions)
            } catch is CancellationError {
                return
            } catch {
                guard documentDeletionPreparationID == preparationID else { return }
                presentDocumentDeleteError(error.localizedDescription)
            }
        }
    }

    private func undoPendingDocumentDeletions(at rowIndexes: IndexSet) {
        guard
            !documentInspectorModel.isCommitting,
            let page = model.selectedObjectDataState.page
        else {
            return
        }
        let references = Set(rowIndexes.compactMap { rowIndex in
            page.row(at: rowIndex).flatMap {
                documentReference(row: $0, columns: page.columns)
            }
        })
        documentInspectorModel.undoDeletions(references: references)
        selectedDataRowIndexes = rowIndexes
    }

    private func beginDeletingRows(_ rowIndexes: IndexSet) {
        guard
            canUseRowActions,
            !rowIndexes.isEmpty,
            let page = model.selectedObjectDataState.page
        else {
            return
        }

        let pendingIndexes = rowIndexes.filter { rowIndex in
            guard let row = page.row(at: rowIndex) else { return false }
            return pendingRowDeletes.contains {
                $0.applies(to: row, columns: page.columns)
            }
        }
        if pendingIndexes.count == rowIndexes.count {
            restorePendingDeletes(at: IndexSet(pendingIndexes), page: page)
            return
        }

        let draftRowIDs = rowIndexes.compactMap(draftRowID(forTableRow:))
        let selectionAnchor = rowIndexes.first ?? 0
        let loadedRowIndexes = IndexSet(rowIndexes.filter {
            page.row(at: $0) != nil && !pendingIndexes.contains($0)
        })
        if loadedRowIndexes.isEmpty {
            draftRowIDs.forEach { rowInsertEditor.removeRow(id: $0) }
            selectNearestActiveDataRow(
                startingAt: selectionAnchor,
                page: page
            )
            return
        }

        let preparationID = UUID()
        rowDeletePreparationID = preparationID
        isPreparingRowDelete = true
        rowDeletePreparationTask = Task { @MainActor in
            defer {
                if rowDeletePreparationID == preparationID {
                    isPreparingRowDelete = false
                    rowDeletePreparationTask = nil
                    rowDeletePreparationID = nil
                }
            }
            await model.loadDetails(for: selection)
            guard
                !Task.isCancelled,
                rowDeletePreparationID == preparationID,
                selectedTab == .data,
                model.selectedObjectDataState.page?.revision == page.revision,
                case let .loaded(details) = model.selectedObjectDetailsState
            else {
                if !Task.isCancelled {
                    presentRowDeleteError(
                        AppCopy.current.text(
                            "无法读取表结构，请重试。",
                            "Unable to load the table structure. Try again."
                        )
                    )
                }
                return
            }
            do {
                var preparedDeletes: [WorkspaceDatabaseInspectorPendingDelete] = []
                for rowIndex in loadedRowIndexes {
                    guard let row = page.row(at: rowIndex) else { continue }
                    let rowDelete = try WorkspaceDatabaseDataRowDeleteRequest.make(
                        selection: selection,
                        rowIndex: rowIndex,
                        page: page,
                        details: details
                    )
                    let replacedUpdates = pendingInspectorUpdates.filter {
                        $0.applies(to: row, columns: page.columns)
                    }
                    preparedDeletes.append(
                        WorkspaceDatabaseInspectorPendingDelete(
                            rowDelete: rowDelete,
                            replacedUpdates: replacedUpdates
                        )
                    )
                }

                for pendingDelete in preparedDeletes {
                    if !pendingRowDeletes.contains(where: {
                        $0.matches(pendingDelete.rowDelete)
                    }) {
                        pendingRowDeletes.append(pendingDelete)
                    }
                    pendingInspectorUpdates.removeAll { update in
                        pendingDelete.replacedUpdates.contains(update)
                    }
                }
                draftRowIDs.forEach { rowInsertEditor.removeRow(id: $0) }
                selectNearestActiveDataRow(
                    startingAt: selectionAnchor,
                    page: page
                )
            } catch {
                presentRowDeleteError(error.localizedDescription)
            }
        }
    }

    private func restorePendingDeletes(
        at rowIndexes: IndexSet,
        page: WorkspaceDatabaseDataPage
    ) {
        let rows = rowIndexes.compactMap(page.row(at:))
        let restoredDeletes = pendingRowDeletes.filter { pendingDelete in
            rows.contains {
                pendingDelete.applies(to: $0, columns: page.columns)
            }
        }
        guard !restoredDeletes.isEmpty else { return }
        pendingRowDeletes.removeAll { restoredDeletes.contains($0) }
        for pendingDelete in restoredDeletes {
            for update in pendingDelete.replacedUpdates
            where !pendingInspectorUpdates.contains(where: {
                $0.matches(update.update)
            }) {
                pendingInspectorUpdates.append(update)
            }
        }
    }

    private func updateRowInsertDraft(
        rowID: UUID,
        columnName: String,
        draft: WorkspaceDatabaseDataRowInsertDraft
    ) {
        if isElasticsearchObject,
           (isSubmittingPendingChanges || (documentInspectorModel.creations.isBlocked
                && !documentInspectorModel.creations.canCorrectDuplicateID)) { return }
        rowInsertEditor.update(
            rowID: rowID,
            columnName: columnName,
            draft: draft
        )
        if isElasticsearchObject, documentInspectorModel.isCreating {
            updateDocumentCreationGridDraft(
                rowID: rowID,
                columnName: columnName,
                draft: draft
            )
        }
    }

    private func requestPendingChangesSubmission() {
        if aliasEditor.hasChanges { aliasEditor.requestCommit(workspace: model); return }
        if indexInspector.hasChanges { indexInspector.requestCommit(workspace: model); return }
        requestPendingChangesSubmission(
            schemaExecutionPlan: makeSchemaExecutionPlan()
        )
    }

    private func requestPendingChangesSubmission(
        schemaExecutionPlan: WorkspaceDatabaseSchemaExecutionPlan?
    ) {
        guard
            hasPendingChanges,
            !isSubmittingPendingChanges,
            pendingChangesSubmissionTask == nil
        else {
            return
        }
        pendingSchemaExecutionPlan = schemaExecutionPlan
        if model.safetyLock.isEnabled {
            showsDisableSafetyLockForRowInsert = true
        } else {
            startPendingChangesSubmission()
        }
    }

    private func startPendingChangesSubmission() {
        if aliasEditor.hasChanges { aliasEditor.requestCommit(workspace: model); return }
        if indexInspector.hasChanges { indexInspector.requestCommit(workspace: model); return }
        if isElasticsearchObject {
            startDocumentChange()
            return
        }
        let inserts: [WorkspaceDatabaseDataRowInsert]
        do {
            inserts = rowInsertEditor.isPresented
                ? try rowInsertEditor.makeInserts()
                : []
        } catch {
            presentRowInsertError(error.localizedDescription)
            return
        }
        let dataChanges = WorkspaceDatabaseDataChangeSet(
            updates: pendingInspectorUpdates.map(\.update),
            inserts: inserts,
            deletes: pendingRowDeletes.map(\.rowDelete)
        )
        let schemaChanges = schemaChangeSet
        guard !dataChanges.isEmpty || !schemaChanges.isEmpty else { return }
        let schemaPlan = pendingSchemaExecutionPlan
        if !schemaChanges.isEmpty, schemaPlan == nil {
            presentCellEditError(
                AppCopy.current.text(
                    "无法生成结构变更 SQL。",
                    "Unable to generate schema change SQL."
                )
            )
            return
        }

        isSubmittingPendingChanges = true
        if rowInsertEditor.isPresented {
            rowInsertEditor.setSubmitting(true)
        }
        pendingChangesSubmissionTask = Task { @MainActor in
            var didApplyDataChanges = false
            defer {
                pendingChangesSubmissionTask = nil
                pendingSchemaExecutionPlan = nil
                isSubmittingPendingChanges = false
            }
            do {
                if !dataChanges.isEmpty {
                    try await model.applyDataChanges(dataChanges)
                    didApplyDataChanges = true
                }
                if let schemaPlan {
                    try await model.applySchemaExecutionPlan(schemaPlan)
                }
                try Task.checkCancellation()
                clearAppliedDataChanges()
                if !schemaChanges.isEmpty {
                    await reloadSchemaEditor()
                }
                if !dataChanges.isEmpty
                    || (!schemaChanges.isEmpty
                        && model.selectedObjectDataState.page != nil)
                {
                    await reloadDataAfterPendingChanges()
                }
            } catch is CancellationError {
                if didApplyDataChanges {
                    clearAppliedDataChanges()
                }
                rowInsertEditor.setSubmitting(false)
                if !schemaChanges.isEmpty {
                    await reloadSchemaEditor()
                }
                if didApplyDataChanges {
                    await reloadDataAfterPendingChanges()
                }
            } catch {
                if didApplyDataChanges {
                    clearAppliedDataChanges()
                }
                rowInsertEditor.setSubmitting(false)
                if !schemaChanges.isEmpty {
                    await reloadSchemaEditor()
                }
                if didApplyDataChanges {
                    await reloadDataAfterPendingChanges()
                }
                presentCellEditError(error.localizedDescription)
            }
        }
    }

    private func clearAppliedDataChanges() {
        pendingInspectorUpdates.removeAll(keepingCapacity: false)
        pendingRowDeletes.removeAll(keepingCapacity: false)
        if rowInsertEditor.isPresented {
            rowInsertEditor.dismiss()
        }
        selectedDataRowIndexes.removeAll()
    }

    private func cancelRowInsert() {
        guard !rowInsertEditor.isSubmitting else { return }
        if isElasticsearchObject, documentInspectorModel.isCreating {
            discardPendingChanges()
            return
        }
        rowInsertEditor.dismiss()
    }

    private func discardPendingChanges() {
        if aliasEditor.hasChanges { aliasEditor.discard(); return }
        if indexInspector.hasChanges { indexInspector.discard(); return }
        if mappingEditor.hasChanges { mappingEditor.discard(); return }
        guard !isSubmittingPendingChanges, !documentInspectorModel.isCommitting else { return }
        if isElasticsearchObject {
            cancelDocumentPaste()
            let deletedRows = pendingDeleteRowIndexes
            documentCellEditingLifetime.finish(commit: false)
            let hadCellChanges = documentInspectorModel.cellChanges.hasChanges
            cancelDocumentDeletionPreparation()
            documentDeletionFailureMessage = nil
            documentCellFailureMessage = nil
            documentCreationFailureMessage = nil
            documentInlineEditSnapshot = nil
            cancelDocumentCreationGridTasks()
            pendingInspectorUpdates.removeAll(keepingCapacity: false)
            documentInspectorModel.discardChanges()
            if rowInsertEditor.isPresented {
                rowInsertEditor.dismiss()
            }
            if !deletedRows.isEmpty {
                selectedDataRowIndexes = deletedRows
            } else if !hadCellChanges {
                selectedDataRowIndexes.removeAll()
            }
            return
        }
        guard
            !rowInsertEditor.isSubmitting,
            !isSubmittingPendingChanges
        else {
            return
        }
        pendingInspectorUpdates.removeAll(keepingCapacity: false)
        if rowInsertEditor.isPresented {
            rowInsertEditor.dismiss()
        }
        pendingRowDeletes.removeAll(keepingCapacity: false)
        pendingSchemaExecutionPlan = nil
        schemaEditor.discardChanges()
        if !schemaEditor.columns.contains(where: { $0.id == selectedSchemaColumnID }) {
            selectedSchemaColumnID = nil
        }
        if !schemaEditor.indexes.contains(where: { $0.id == selectedSchemaIndexID }) {
            selectedSchemaIndexID = nil
        }
    }

    private func updateSchemaColumn(
        id: UUID,
        definition: WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) {
        guard selection.kind == .table else { return }
        schemaEditor.updateColumn(id: id, definition: definition)
    }

    private func setSchemaColumnPrimaryKey(id: UUID, isEnabled: Bool) {
        guard selection.kind == .table else { return }
        var updatedEditor = schemaEditor
        updatedEditor.setPrimaryKey(columnID: id, isEnabled: isEnabled)
        schemaEditor = updatedEditor
    }

    private func addSchemaColumn() {
        guard selection.kind == .table else { return }
        selectedSchemaColumnID = schemaEditor.addColumn(
            defaultType: model.schemaEditingDescriptor.defaultColumnType
        )
    }

    private func duplicateSchemaColumn(id: UUID) {
        guard selection.kind == .table else { return }
        selectedSchemaColumnID = schemaEditor.duplicateColumn(id: id)
            ?? selectedSchemaColumnID
    }

    private func deleteSchemaColumn(id: UUID) {
        guard selection.kind == .table else { return }
        selectedSchemaColumnID = schemaEditor.deleteColumn(id: id)
    }

    private func updateSchemaIndex(
        id: UUID,
        definition: WorkspaceDatabaseSchemaEditorState.IndexDefinition
    ) {
        guard selection.kind == .table else { return }
        schemaEditor.updateIndex(id: id, definition: definition)
    }

    private func addSchemaIndex() {
        guard selection.kind == .table else { return }
        selectedSchemaIndexID = schemaEditor.addIndex(
            defaultMethod: model.schemaEditingDescriptor.indexMethods.first ?? ""
        )
    }

    private func duplicateSchemaIndex(id: UUID) {
        guard selection.kind == .table else { return }
        selectedSchemaIndexID = schemaEditor.duplicateIndex(id: id)
            ?? selectedSchemaIndexID
    }

    private func deleteSchemaIndex(id: UUID) {
        guard selection.kind == .table else { return }
        selectedSchemaIndexID = schemaEditor.deleteIndex(id: id)
    }

    private func syncSchemaEditorFromLoadedStates() {
        if case let .loaded(details) = model.selectedObjectDetailsState {
            schemaEditor.loadColumnsIfNeeded(
                details.columns,
                schemaChoices: details.schemaChoices
            )
            if let tableInformation = details.tableInformation {
                schemaEditor.loadTableOptionsIfNeeded(
                    tableInformation.tableOptions
                )
            }
        }
        if case let .loaded(indexes) = model.selectedObjectIndexesState {
            schemaEditor.loadIndexesIfNeeded(indexes)
        }
    }

    private func reloadSchemaEditor() async {
        async let details: Void = model.loadDetails(for: selection, force: true)
        async let indexes: Void = model.loadIndexes(for: selection, force: true)
        _ = await (details, indexes)
        var reloadedEditor = WorkspaceDatabaseSchemaEditorState()
        if case let .loaded(details) = model.selectedObjectDetailsState {
            reloadedEditor.loadColumnsIfNeeded(
                details.columns,
                schemaChoices: details.schemaChoices
            )
            if let tableInformation = details.tableInformation {
                reloadedEditor.loadTableOptionsIfNeeded(
                    tableInformation.tableOptions
                )
            }
        }
        if case let .loaded(indexes) = model.selectedObjectIndexesState {
            reloadedEditor.loadIndexesIfNeeded(indexes)
        }
        schemaEditor = reloadedEditor
        selectedSchemaColumnID = nil
        selectedSchemaIndexID = nil
    }

    private func reloadDataAfterPendingChanges() async {
        await model.loadData(
            for: selection,
            offset: dataOffset,
            limit: dataLimit,
            sort: dataSort,
            filter: currentAppliedDataFilter,
            force: true
        )
    }

    private func selectRowsForActions(_ rowIndexes: IndexSet) {
        guard !isSubmittingPendingChanges, !indexInspector.isCommitting,
              !aliasEditor.isCommitting else { return }
        if rowIndexes.isEmpty, rowInsertEditor.isPresented {
            return
        }
        if rowIndexes.isEmpty,
           documentInspectorModel.blocksDocumentSelectionChanges
        {
            return
        }
        if documentInspectorModel.blocksDocumentSelectionChanges,
           rowIndexes != selectedDataRowIndexes
        {
            showsDocumentDraftNavigationBlocked = true
            return
        }
        selectedDataRowIndexes = rowIndexes
    }

    private func selectNearestActiveDataRow(
        startingAt rowIndex: Int,
        page: WorkspaceDatabaseDataPage
    ) {
        let nearestIndex = WorkspaceDatabaseDataRowSelection.nearestActiveIndex(
            startingAt: rowIndex,
            totalRowCount: page.rowCount + rowInsertEditor.rowCount,
            excludedRowIndexes: pendingDeleteRowIndexes
        )
        selectedDataRowIndexes = nearestIndex.map(IndexSet.init(integer:))
            ?? IndexSet()
    }

    private var lastDraftTableRowIndex: Int? {
        guard
            let page = model.selectedObjectDataState.page,
            rowInsertEditor.rowCount > 0
        else {
            return nil
        }
        return page.rowCount + rowInsertEditor.rowCount - 1
    }

    private func selectLastDraftRow() {
        selectedDataRowIndexes = lastDraftTableRowIndex.map(IndexSet.init(integer:))
            ?? IndexSet()
    }

    private func draftRowID(forTableRow rowIndex: Int) -> UUID? {
        guard let page = model.selectedObjectDataState.page else { return nil }
        return rowInsertEditor.rowID(at: rowIndex - page.rowCount)
    }

    private func canDuplicateRow(_ rowIndex: Int) -> Bool {
        guard canUseRowActions else { return false }
        if draftRowID(forTableRow: rowIndex) != nil {
            return true
        }
        guard
            let page = model.selectedObjectDataState.page,
            let row = page.row(at: rowIndex)
        else {
            return false
        }
        return !pendingRowDeletes.contains {
            $0.applies(to: row, columns: page.columns)
        }
    }

    private func canDuplicateDocument(_ rowIndex: Int) -> Bool {
        guard
            canCreateDocument,
            let page = model.selectedObjectDataState.page,
            let row = page.row(at: rowIndex),
            documentReference(row: row, columns: page.columns) != nil
        else {
            return false
        }
        return !pendingDeleteRowIndexes.contains(rowIndex)
    }

    private func canDeleteRows(_ rowIndexes: IndexSet) -> Bool {
        guard canUseRowActions, !rowIndexes.isEmpty else { return false }
        return rowIndexes.allSatisfy { rowIndex in
            if draftRowID(forTableRow: rowIndex) != nil {
                return true
            }
            guard
                let page = model.selectedObjectDataState.page,
                let row = page.row(at: rowIndex)
            else {
                return false
            }
            return !pendingRowDeletes.contains {
                $0.applies(to: row, columns: page.columns)
            }
        }
    }

    private func presentCellEditError(_ message: String) {
        cellEditErrorMessage = message
        showsCellEditError = true
    }

    private func presentRowInsertError(_ message: String) {
        rowInsertErrorMessage = message
        showsRowInsertError = true
    }

    private func presentRowDeleteError(_ message: String) {
        rowDeleteErrorMessage = message
        showsRowDeleteError = true
    }

    private func presentDocumentDeleteError(_ message: String) {
        documentDeleteErrorMessage = message
        showsDocumentDeleteError = true
    }

    private var documentConflictTitle: String {
        if documentCreationFailureMessage != nil {
            return AppCopy.current.text("文档新增未完成", "Document Creation Incomplete")
        }
        if documentCellFailureMessage != nil {
            return AppCopy.current.text("文档更新未完成", "Document Update Incomplete")
        }
        if documentDeletionFailureMessage != nil {
            return AppCopy.current.text("文档删除未完成", "Document Deletion Incomplete")
        }
        if documentConflictError == .documentNotFound {
            return AppCopy.current.text(
                "文档已不存在",
                "Document No Longer Exists"
            )
        }
        return AppCopy.current.text("文档已发生变化", "Document Changed")
    }

    private var documentNavigationBlockTitle: String {
        if aliasEditor.hasChanges { return AppCopy.current.text("先处理 Alias 更改", "Resolve Alias Changes") }
        if indexInspector.hasChanges { return AppCopy.current.text("先处理索引设置更改", "Resolve Index Settings Changes") }
        if mappingEditor.hasChanges { return AppCopy.current.text("先处理 Mapping 更改", "Resolve Mapping Changes") }
        if documentInspectorModel.isPendingDeletion {
            return AppCopy.current.text(
                "已有待删除文档",
                "Document Deletion Pending"
            )
        }
        return AppCopy.current.text(
            "先处理文档更改",
            "Resolve Document Changes"
        )
    }

    private var documentNavigationBlockActionTitle: String {
        if documentInspectorModel.isPendingDeletion {
            return AppCopy.current.text("继续浏览", "Continue Browsing")
        }
        return AppCopy.current.text("继续编辑", "Continue Editing")
    }

    private var documentNavigationBlockMessage: String {
        if aliasEditor.hasChanges {
            return AppCopy.current.text(
                "可以继续选择和查看文档或字段。修改数据、翻页、筛选或刷新前，请通过顶部工具栏提交或放弃 Alias 更改。",
                "You can continue selecting and viewing documents or fields. Commit or discard alias changes from the top toolbar before editing data, paging, filtering, or refreshing."
            )
        }
        if indexInspector.hasChanges {
            return AppCopy.current.text("可以继续选择和查看文档或字段。修改数据、翻页、筛选或刷新前，请通过顶部工具栏提交或放弃索引设置。", "You can continue selecting and viewing documents or fields. Commit or discard index settings from the top toolbar before editing data, paging, filtering, or refreshing.")
        }
        if mappingEditor.hasChanges {
            return AppCopy.current.text("可以继续在此 Mapping 中选择和编辑字段。切换内容、刷新或关闭前，请先通过工具栏提交或放弃更改。", "You can keep selecting and editing fields in this Mapping. Commit or discard from the toolbar before switching content, refreshing or closing.")
        }
        if documentInspectorModel.cellChanges.hasChanges {
            return AppCopy.current.text(
                "可以继续选择和查看其他文档；未发生提交错误时也可以继续编辑单元格。新增、删除、完整 JSON 编辑、翻页、筛选或刷新前，请先提交或放弃这些更改。",
                "You can keep selecting and viewing documents, and edit cells until a submission error occurs. Commit or discard these changes before creating, deleting, editing full JSON, paging, filtering, or refreshing."
            )
        }
        if documentInspectorModel.isPendingDeletion {
            return AppCopy.current.text(
                "可以继续选择和查看其他文档。如需修改文档、翻页、筛选或刷新，请先通过工具栏提交或放弃当前删除。",
                "You can continue selecting and viewing other documents. To edit documents, change pages, filter, or refresh, commit or discard the pending deletion from the toolbar first."
            )
        }
        return AppCopy.current.text(
            "请先通过工具栏提交或放弃当前文档更改。",
            "Commit or discard the current document changes from the toolbar first."
        )
    }

    private var documentConflictMessage: String {
        if let documentCreationFailureMessage { return documentCreationFailureMessage }
        if let documentCellFailureMessage { return documentCellFailureMessage }
        if let documentDeletionFailureMessage { return documentDeletionFailureMessage }
        if documentConflictError == .documentNotFound {
            return AppCopy.current.text(
                "服务器上已找不到这篇文档。待删除状态仍保留，但不能继续提交；重新加载会放弃本地状态并刷新列表。",
                "The document can no longer be found on the server. The pending deletion is preserved but cannot be committed again; reloading discards local state and refreshes the list."
            )
        }
        if documentInspectorModel.isPendingDeletion {
            return AppCopy.current.text(
                "服务器上的文档已被其他操作修改。待删除状态仍保留，但不能继续提交；重新加载会放弃本地状态。",
                "The server document was changed elsewhere. The pending deletion is preserved but cannot be committed again; reloading discards local state."
            )
        }
        return AppCopy.current.text(
            "服务器上的文档已被其他操作修改。草稿仍保留，但不能继续提交；重新加载会放弃草稿。",
            "The server document was changed elsewhere. The draft is preserved but cannot be committed again; reloading discards it."
        )
    }

    private func cancelDetailTasks() {
        pendingDocumentPaste = nil
        documentCellEditingLifetime.finish(commit: false)
        documentInspectorModel.cancelLoading()
        documentInspectorModel.cellChanges.cancelValidation()
        documentInlineEditSnapshot = nil
        cancelDataFilterDetailsTask()
        rowInsertPreparationTask?.cancel()
        rowInsertPreparationTask = nil
        rowInsertPreparationID = nil
        isPreparingRowInsert = false
        rowDeletePreparationTask?.cancel()
        rowDeletePreparationTask = nil
        rowDeletePreparationID = nil
        isPreparingRowDelete = false
        cancelDocumentDeletionPreparation()
        documentDeletionRecoveryTask?.cancel()
        documentDeletionRecoveryTask = nil
        cancelDocumentDuplication()
        pendingChangesSubmissionTask?.cancel()
        pendingChangesSubmissionTask = nil
        documentSubmissionID = nil
        documentCreationPresentation = nil
        cancelDocumentCreationGridTasks()
        isSubmittingPendingChanges = false
        pendingRefreshRequest = nil
        showsRefreshCompletion = false
    }

    private func cancelDocumentDuplication() {
        documentDuplicationTask?.cancel()
        documentDuplicationTask = nil
        documentDuplicationID = nil
        pendingDocumentDuplicationRowIndex = nil
        isPreparingDocumentDuplication = false
    }

    private func cancelDocumentDeletionPreparation() {
        documentDeletionPreparationTask?.cancel()
        documentDeletionPreparationTask = nil
        documentDeletionPreparationID = nil
        pendingDocumentDeletionRows = []
        isPreparingDocumentDeletion = false
    }

    private func requestDocumentEditing() {
        guard !aliasEditor.hasChanges, !aliasEditor.isCommitting,
              !indexInspector.hasChanges, !indexInspector.isCommitting else {
            showsDocumentDraftNavigationBlocked = true; return
        }
        guard isElasticsearchObject, !isPreparingDocumentDeletion else { return }
        if model.safetyLock.isEnabled {
            showsDisableSafetyLockForDocumentEdit = true
        } else {
            startDocumentEditing()
        }
    }

    private func beginDocumentCreation() {
        guard canCreateDocument else { return }
        pendingDocumentDuplicationRowIndex = nil
        pendingDocumentPaste = nil
        if model.safetyLock.isEnabled {
            showsDisableSafetyLockForDocumentCreation = true
        } else {
            startDocumentCreation()
        }
    }

    private func beginDuplicatingDocument(_ rowIndex: Int) {
        guard canDuplicateDocument(rowIndex) else { return }
        pendingDocumentPaste = nil
        pendingDocumentDuplicationRowIndex = rowIndex
        selectedDataRowIndexes = IndexSet(integer: rowIndex)
        if model.safetyLock.isEnabled {
            showsDisableSafetyLockForDocumentCreation = true
        } else {
            startPendingDocumentCreation()
        }
    }

    private func startPendingDocumentCreation() {
        if let paste = pendingDocumentPaste {
            pendingDocumentPaste = nil
            startDocumentPaste(paste.0, targetColumnNames: paste.1, selectedDraftRowID: paste.2)
        } else if let rowIndex = pendingDocumentDuplicationRowIndex {
            startDocumentDuplication(at: rowIndex)
        } else {
            startDocumentCreation()
        }
    }

    private func startDocumentCreation() {
        appendDocumentCreation(sourceJSON: Data("{}".utf8), routing: nil)
    }

    private func cancelDocumentPaste() {
        pendingDocumentPaste = nil
        rowInsertPreparationTask?.cancel()
        rowInsertPreparationTask = nil
        rowInsertPreparationID = nil
        isPreparingRowInsert = false
    }

    private func startDocumentPaste(
        _ content: WorkspaceGridPasteboardContent, targetColumnNames: [String], selectedDraftRowID: UUID?
    ) {
        guard canCreateDocument, let page = model.selectedObjectDataState.page else { return }
        let request = rowInsertEditor.request ?? .makeElasticsearchDocument(selection: selection, pageColumns: page.columns)
        let editorRevision = rowInsertEditor.revision
        let batchRevision = documentInspectorModel.creations.mutationRevision
        let replacement = selectedDraftRowID.flatMap { id in
            documentInspectorModel.creations.isEmptyCreation(id) ? id : nil
        }
        let preparationID = UUID()
        rowInsertPreparationID = preparationID
        isPreparingRowInsert = true
        rowInsertPreparationTask = Task { @MainActor in
            defer {
                if rowInsertPreparationID == preparationID {
                    rowInsertPreparationTask = nil
                    rowInsertPreparationID = nil
                    isPreparingRowInsert = false
                }
            }
            do {
                await model.loadDetails(for: selection)
                try Task.checkCancellation()
                guard rowInsertPreparationID == preparationID,
                      case let .loaded(details) = model.selectedObjectDetailsState,
                      let mappingFields = details.documentMappingFields else {
                    throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
                }
                var documents = try await WorkspaceElasticsearchDocumentPasteParser.shared.parse(
                    content, targetColumnNames: targetColumnNames, request: request,
                    targetKind: documentCreationTargetKind, mappingFields: mappingFields
                )
                if let replacement, let first = documents.first {
                    documents[0] = WorkspaceElasticsearchPastedDocument(
                        row: WorkspaceDatabaseDataRowInsertDraftRow(id: replacement, drafts: first.row.drafts,
                            editedColumnNames: first.row.editedColumnNames),
                        draft: first.draft, sourceText: first.sourceText)
                }
                var prepared: [WorkspacePreparedDocumentCreation] = []
                for document in documents {
                    try Task.checkCancellation()
                    prepared.append(try await model.prepareDocumentCreation(document.draft))
                }
                try Task.checkCancellation()
                guard rowInsertPreparationID == preparationID, selectedTab == .data,
                      model.selectedObjectDataState.page?.revision == page.revision,
                      rowInsertEditor.revision == editorRevision,
                      documentInspectorModel.creations.mutationRevision == batchRevision,
                      !documentInspectorModel.isCommitting,
                      documentInspectorModel.editingState == .viewing,
                      !documentInspectorModel.hasChanges || documentInspectorModel.creations.hasChanges else {
                    throw WorkspaceDatabaseDataRowInsertError.editingContextChanged
                }
                var editor = rowInsertEditor
                if editor.isPresented {
                    try editor.applyPastedRows(documents.map(\.row), replacingRowID: replacement)
                } else {
                    try editor.present(request, pastedRows: documents.map(\.row))
                }
                try documentInspectorModel.creations.installPaste(documents, prepared: prepared, replacingEmptyRowID: replacement)
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    rowInsertEditor = editor
                    let firstRow = page.rowCount + (editor.rowIndex(id: documents[0].row.id) ?? 0)
                    selectedDataRowIndexes = IndexSet(integersIn: firstRow..<(firstRow + documents.count))
                }
            } catch is CancellationError {
                return
            } catch {
                guard rowInsertPreparationID == preparationID else { return }
                presentRowInsertError(error.localizedDescription)
            }
        }
    }

    private func appendDocumentCreation(sourceJSON: Data, routing: String?) {
        guard canCreateDocument, let page = model.selectedObjectDataState.page else { return }
        var editor = rowInsertEditor
        if editor.isPresented {
            editor.appendRow()
        } else {
            editor.present(WorkspaceDatabaseDataRowInsertRequest.makeElasticsearchDocument(
                selection: selection, pageColumns: page.columns
            ))
        }
        guard let rowID = editor.rowIDs.last else { return }
        do {
            try documentInspectorModel.addCreation(rowID: rowID, targetName: selection.objectName,
                targetKind: documentCreationTargetKind, sourceJSON: sourceJSON, routing: routing) { draft in
                try await model.prepareDocumentCreation(draft)
            }
            rowInsertEditor = editor
            selectedDataRowIndexes = IndexSet(integer: page.rowCount + editor.rowCount - 1)
            if let child = documentInspectorModel.creations.entries[rowID] {
                documentInspectorModel.creations.project(rowID: rowID, fieldNames: documentCreationFieldNames)
                child.creationRouting = routing ?? ""
            }
        } catch {
            presentDocumentCommitError(error.localizedDescription)
        }
    }

    private func startDocumentDuplication(at rowIndex: Int) {
        guard canDuplicateDocument(rowIndex), let page = model.selectedObjectDataState.page,
              let row = page.row(at: rowIndex),
              let reference = documentReference(row: row, columns: page.columns) else {
            pendingDocumentDuplicationRowIndex = nil
            return
        }
        pendingDocumentDuplicationRowIndex = nil
        let duplicationID = UUID()
        let pageRevision = page.revision
        documentDuplicationID = duplicationID
        isPreparingDocumentDuplication = true
        documentDuplicationTask = Task { @MainActor in
            defer {
                if documentDuplicationID == duplicationID {
                    documentDuplicationTask = nil
                    documentDuplicationID = nil
                    isPreparingDocumentDuplication = false
                }
            }
            do {
                let snapshot = try await model.fetchDocument(reference)
                try Task.checkCancellation()
                guard !snapshot.isTruncated else {
                    throw WorkspaceDocumentEditingError.sourceTooLarge(
                        WorkspaceElasticsearchDocumentValidator.maximumByteCount)
                }
                guard documentDuplicationID == duplicationID, selectedTab == .data,
                      model.selectedObjectDataState.page?.revision == pageRevision else { return }
                documentDuplicationTask = nil
                isPreparingDocumentDuplication = false
                appendDocumentCreation(sourceJSON: snapshot.sourceJSON, routing: snapshot.reference.routing)
            } catch is CancellationError {
                return
            } catch {
                guard documentDuplicationID == duplicationID else { return }
                presentDocumentCommitError(error.localizedDescription)
            }
        }
    }

    private var documentCreationTargetKind: WorkspaceDocumentCreationTargetKind {
        switch selection.kind {
        case .elasticsearchAlias: .alias
        case .elasticsearchDataStream: .dataStream
        default: .index
        }
    }

    private var documentCreationFieldNames: Set<String> {
        Set((rowInsertEditor.request?.columns ?? []).map(\.id).filter { $0 != "_id" && $0 != "_routing" })
    }

    private func updateDocumentCreationDraft(rowID: UUID, documentID: String, routing: String, text: String) {
        documentInspectorModel.creations.updateInspector(rowID: rowID, documentID: documentID,
            routing: routing, text: text, fieldNames: documentCreationFieldNames) { draft in
            try await model.prepareDocumentCreation(draft)
        }
    }

    private func updateDocumentCreationGridDraft(
        rowID: UUID, columnName: String, draft: WorkspaceDatabaseDataRowInsertDraft
    ) {
        guard let row = rowInsertEditor.draftRows.first(where: { $0.id == rowID }) else { return }
        documentInspectorModel.creations.updateGrid(row: row) { draft in
            try await model.prepareDocumentCreation(draft)
        }
    }

    private func cancelDocumentCreationGridTasks() {
        documentInspectorModel.creations.cancelTasks()
    }

    private func startDocumentEditing() {
        guard !aliasEditor.hasChanges, !aliasEditor.isCommitting,
              !indexInspector.hasChanges, !indexInspector.isCommitting else {
            showsDocumentDraftNavigationBlocked = true; return
        }
        do {
            try documentInspectorModel.beginEditing()
        } catch {
            presentDocumentCommitError(error.localizedDescription)
        }
    }

    private func updateDocumentDraft(_ text: String) {
        documentInspectorModel.updateDraft(text) { draft in
            try await model.prepareDocumentReplacement(draft)
        }
    }

    private func endDocumentEditing() {
        if documentInspectorModel.hasChanges {
            showsDocumentDraftNavigationBlocked = true
        } else {
            documentInspectorModel.discardChanges()
        }
    }

    private func allowDocumentDraftInvalidation() -> Bool {
        guard !aliasEditor.hasChanges, !aliasEditor.isCommitting else {
            showsDocumentDraftNavigationBlocked = true; return false
        }
        guard !indexInspector.hasChanges, !indexInspector.isCommitting else {
            showsDocumentDraftNavigationBlocked = true; return false
        }
        guard !mappingEditor.hasChanges, !mappingEditor.isCommitting else {
            showsDocumentDraftNavigationBlocked = true; return false
        }
        guard !isSubmittingPendingChanges else { return false }
        guard !documentInspectorModel.hasChanges else {
            showsDocumentDraftNavigationBlocked = true
            return false
        }
        cancelDocumentDeletionPreparation()
        cancelDocumentPaste()
        return true
    }

    private func addMappingField() {
        guard !aliasEditor.hasChanges, !aliasEditor.isCommitting,
              !indexInspector.hasChanges, !indexInspector.isCommitting else {
            showsDocumentDraftNavigationBlocked = true; return
        }
        guard !documentInspectorModel.hasChanges else { showsDocumentDraftNavigationBlocked = true; return }
        mappingEditor.requestEdit(workspace: model) { mappingEditor.add(workspace: model) }
    }

    private func startDocumentChange() {
        documentCellEditingLifetime.finish(commit: true)
        guard pendingChangesSubmissionTask == nil,
              !isPreparingDocumentDeletion,
              !isPreparingRowInsert,
              let change = documentInspectorModel.beginCommit()
        else { return }
        let isCreation: Bool
        if documentInspectorModel.isCreating {
            isCreation = true
            if rowInsertEditor.isPresented {
                rowInsertEditor.setSubmitting(true)
            }
        } else {
            isCreation = false
        }
        let deletionRowIndex = pendingDeleteRowIndexes.first
        let selectedReference = selectedDocumentReference
        let submissionID = UUID()
        documentSubmissionID = submissionID
        documentDeletionFailureMessage = nil
        documentCellFailureMessage = nil
        documentCreationFailureMessage = nil
        isSubmittingPendingChanges = true
        if case .creations = change {
            documentCreationPresentation = WorkspaceElasticsearchCreationTablePresentation(
                dataState: model.selectedObjectDataState,
                countState: model.selectedObjectDataCountState,
                rowInsertEditor: rowInsertEditor,
                selectedRowIndexes: selectedDataRowIndexes
            )
        }
        pendingChangesSubmissionTask = Task { @MainActor in
            defer {
                if documentSubmissionID == submissionID {
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        // Publish the refreshed page and remaining drafts together, never per acknowledgement.
                        documentCreationPresentation = nil
                        documentSubmissionID = nil
                        pendingChangesSubmissionTask = nil
                        isSubmittingPendingChanges = false
                    }
                }
            }
            do {
                switch change {
                case .creations(let first, let rest):
                    let results = try await documentInspectorModel.commitPreparedCreations(rows: [first] + rest) { creation in
                        try await model.commitDocumentCreation(creation)
                    }
                    guard documentSubmissionID == submissionID else { return }
                    rowInsertEditor.dismiss()
                    documentDeletionRecoveryTask = Task { @MainActor in
                        await reloadDataAfterPendingChanges()
                        guard documentSubmissionID == submissionID else { return }
                        if let reference = results.last?.reference { restoreDocumentSelection(reference) }
                    }
                    await documentDeletionRecoveryTask?.value
                    guard documentSubmissionID == submissionID else { return }
                    documentDeletionRecoveryTask = nil
                case .creation(let creation):
                    let result = try await model.commitDocumentCreation(creation)
                    guard documentSubmissionID == submissionID else { return }
                    documentInspectorModel.finishCreationCommit(result)
                    cancelDocumentCreationGridTasks()
                    if rowInsertEditor.isPresented {
                        rowInsertEditor.dismiss()
                    }
                    await reloadConfirmedDocument(result.reference, submissionID: submissionID)
                case .replacement(let replacement):
                    let result = try await model.commitDocumentReplacement(
                        replacement
                    )
                    guard documentSubmissionID == submissionID else { return }
                    documentInspectorModel.finishCommit(result)
                    await reloadConfirmedDocument(result.reference, submissionID: submissionID)
                case .partialUpdate(let update):
                    let result = try await model.commitDocumentPartialUpdate(
                        update
                    )
                    guard documentSubmissionID == submissionID else { return }
                    documentInspectorModel.finishCommit(result)
                    await reloadConfirmedDocument(result.reference, submissionID: submissionID)
                case .partialUpdates(let first, let rest):
                    try await documentInspectorModel.commitPreparedCellChanges(updates: [first] + rest) { update in
                        try await model.commitDocumentPartialUpdate(update)
                    }
                    guard documentSubmissionID == submissionID else { return }
                    pendingInspectorUpdates.removeAll(keepingCapacity: false)
                    documentInlineEditSnapshot = nil
                    documentDeletionRecoveryTask = Task { @MainActor in
                        await reloadDataAfterPendingChanges()
                        guard documentSubmissionID == submissionID else { return }
                        if let selectedReference {
                            restoreDocumentSelection(selectedReference)
                            if selectedDocumentReference == selectedReference {
                                await documentInspectorModel.load(reference: selectedReference) { reference in
                                    try await model.fetchDocument(reference)
                                }
                            }
                        }
                    }
                    await documentDeletionRecoveryTask?.value
                    guard documentSubmissionID == submissionID else { return }
                    documentDeletionRecoveryTask = nil
                case .deletion, .deletions:
                    try await documentInspectorModel.commitPreparedDeletions { deletion in
                        try await model.commitDocumentDeletion(deletion)
                    }
                    guard documentSubmissionID == submissionID else { return }
                    documentDeletionRecoveryTask = Task { @MainActor in
                        await reloadDataAfterPendingChanges()
                    }
                    await documentDeletionRecoveryTask?.value
                    guard documentSubmissionID == submissionID else { return }
                    documentDeletionRecoveryTask = nil
                    if let page = model.selectedObjectDataState.page {
                        selectNearestActiveDataRow(
                            startingAt: deletionRowIndex ?? 0,
                            page: page
                        )
                    } else {
                        selectedDataRowIndexes = []
                    }
                }
                pendingInspectorUpdates.removeAll(keepingCapacity: false)
            } catch is CancellationError {
                if case .creations = change {
                    await handleDocumentCreationFailure(CancellationError(), originalCount: change.requests.count,
                        submissionID: submissionID)
                    return
                }
                if case .partialUpdates = change {
                    await handleDocumentCellFailure(CancellationError(), originalCount: change.requests.count,
                        submissionID: submissionID)
                    return
                }
                if change.isDeletion {
                    await handleDocumentDeletionFailure(
                        CancellationError(), originalCount: change.deletions.count,
                        submissionID: submissionID
                    )
                    return
                }
                await handleSingleDocumentCancellation(change, submissionID: submissionID)
            } catch {
                if case .creations = change {
                    await handleDocumentCreationFailure(error, originalCount: change.requests.count,
                        submissionID: submissionID)
                    return
                }
                if case .partialUpdates = change {
                    await handleDocumentCellFailure(error, originalCount: change.requests.count,
                        submissionID: submissionID)
                    return
                }
                if change.isDeletion {
                    await handleDocumentDeletionFailure(
                        error, originalCount: change.deletions.count,
                        submissionID: submissionID
                    )
                    return
                }
                if isCreation, rowInsertEditor.isPresented {
                    rowInsertEditor.setSubmitting(false)
                }
                documentInspectorModel.finishCommitFailure(error)
                if let editingError = error as? WorkspaceDocumentEditingError,
                   editingError == .conflict
                    || editingError == .documentNotFound
                {
                    documentConflictError = editingError
                    showsDocumentConflict = true
                } else {
                    presentDocumentCommitError(error.localizedDescription)
                }
            }
        }
    }

    private func reloadConfirmedDocument(
        _ reference: WorkspaceDocumentReference, submissionID: UUID
    ) async {
        documentDeletionRecoveryTask = Task { @MainActor in
            await reloadDataAfterPendingChanges()
            guard documentSubmissionID == submissionID else { return }
            restoreDocumentSelection(reference)
        }
        await documentDeletionRecoveryTask?.value
        guard documentSubmissionID == submissionID else { return }
        documentDeletionRecoveryTask = nil
    }

    private func handleSingleDocumentCancellation(
        _ change: WorkspacePreparedDocumentChange, submissionID: UUID
    ) async {
        guard documentSubmissionID == submissionID else { return }
        documentInspectorModel.finishCommitFailure(CancellationError())
        let message = AppCopy.current.text(
            "请求已取消，但服务器是否已保存仍需核实。草稿已保留，不能直接重试。重新加载会放弃草稿并读取服务器状态；放弃全部也不会撤销服务器上已完成的操作。",
            "The request was cancelled, but whether the server saved it still needs verification. Your draft is retained and direct retry is disabled. Reload discards the draft and reads server state; Discard All cannot undo an operation already completed on the server."
        )
        if case .creation = change {
            documentCreationFailureMessage = message
        } else {
            documentCellFailureMessage = message
        }
        // Recovery is owned separately so cancelling submission does not cancel the read.
        documentDeletionRecoveryTask = Task { @MainActor in
            await reloadDataAfterPendingChanges()
        }
        await documentDeletionRecoveryTask?.value
        guard documentSubmissionID == submissionID else { return }
        documentDeletionRecoveryTask = nil
        showsDocumentConflict = true
    }

    private func handleDocumentDeletionFailure(
        _ error: Error,
        originalCount: Int,
        submissionID: UUID
    ) async {
        guard documentSubmissionID == submissionID else { return }
        let remaining = documentInspectorModel.preparedDeletions
        let succeeded = originalCount - remaining.count
        let reference = remaining.first?.draft.reference
        documentInspectorModel.finishCommitFailure(WorkspaceDocumentEditingError.conflict)
        let identity = reference.map { "\($0.index) / \($0.id)" } ?? ""
        let reason = error is CancellationError
            ? AppCopy.current.text("请求已取消，最后一篇文档的执行结果需要核实。", "The request was cancelled; the last document's outcome needs verification.")
            : error.localizedDescription
        documentDeletionFailureMessage = AppCopy.current.text(
            "已确认删除 \(succeeded) 篇，保留 \(remaining.count) 篇待处理。\n\(identity)\n\(reason)\n已停止后续删除。重新加载会清除剩余待删除标记并读取服务器状态；已成功删除的文档无法撤销。",
            "Confirmed \(succeeded) deleted; \(remaining.count) remain pending.\n\(identity)\n\(reason)\nSubsequent deletions have stopped. Reload clears the remaining pending deletions and reads the server state; successful deletions cannot be undone."
        )
        // Recovery must outlive cancellation of the write request, but remains owned by this view.
        documentDeletionRecoveryTask = Task { @MainActor in
            await reloadDataAfterPendingChanges()
        }
        await documentDeletionRecoveryTask?.value
        guard documentSubmissionID == submissionID else { return }
        documentDeletionRecoveryTask = nil
        showsDocumentConflict = true
    }

    private func handleDocumentCreationFailure(_ error: Error, originalCount: Int, submissionID: UUID) async {
        guard documentSubmissionID == submissionID else { return }
        let batch = documentInspectorModel.creations
        rowInsertEditor.setSubmitting(false)
        rowInsertEditor.retainDraftRows(Set(batch.order))
        if !batch.canCorrectDuplicateID { rowInsertEditor.setSubmitting(true) }
        let remaining = batch.order.count
        let reason = error is CancellationError
            ? AppCopy.current.text("请求已取消，最后一次创建的结果需要核实。", "The request was cancelled; the last creation's outcome needs verification.")
            : error.localizedDescription
        let correction = batch.canCorrectDuplicateID
            ? AppCopy.current.text("可以修改失败草稿的 _id，再提交剩余文档。", "Change the failed draft's _id to submit the remaining documents.")
            : AppCopy.current.text("结果尚未核实，已禁止直接重试，尤其不能重复发送自动 ID 创建请求。", "Direct retry is disabled until the outcome is verified, especially for auto-ID creation requests.")
        documentCreationFailureMessage = AppCopy.current.text(
            "已确认新增 \(originalCount - remaining) 篇，保留 \(remaining) 篇草稿。\n\(reason)\n\(correction)\n重新加载会放弃剩余草稿并读取服务器状态；已成功新增的文档不会撤销。",
            "Confirmed \(originalCount - remaining) created; \(remaining) drafts retained.\n\(reason)\n\(correction)\nReload discards the remaining drafts and reads server state; successful creations cannot be undone."
        )
        documentDeletionRecoveryTask = Task { @MainActor in
            await reloadDataAfterPendingChanges()
            guard documentSubmissionID == submissionID else { return }
            if let first = batch.failedRowID ?? batch.order.first,
               let index = rowInsertEditor.rowIndex(id: first),
               let page = model.selectedObjectDataState.page {
                selectedDataRowIndexes = IndexSet(integer: page.rowCount + index)
            }
        }
        await documentDeletionRecoveryTask?.value
        guard documentSubmissionID == submissionID else { return }
        documentDeletionRecoveryTask = nil
        showsDocumentConflict = true
    }

    private func handleDocumentCellFailure(
        _ error: Error, originalCount: Int, submissionID: UUID
    ) async {
        guard documentSubmissionID == submissionID else { return }
        let remaining = documentInspectorModel.cellChanges.order
        let remainingSet = Set(remaining)
        pendingInspectorUpdates.removeAll { pending in
            guard let reference = WorkspaceElasticsearchCellChangesModel.reference(for: pending.update) else { return true }
            return !remainingSet.contains(reference)
        }
        let identity = remaining.first.map { "\($0.index) / \($0.id)" } ?? ""
        let reason = error is CancellationError
            ? AppCopy.current.text("请求已取消，最后一次更新的结果需要核实。", "The request was cancelled; the last update's outcome needs verification.")
            : error.localizedDescription
        documentCellFailureMessage = AppCopy.current.text(
            "已确认更新 \(originalCount - remaining.count) 篇，保留 \(remaining.count) 篇草稿。\n\(identity)\n\(reason)\n后续更新已停止，不能直接重试。重新加载会放弃剩余草稿并读取服务器状态；放弃全部也不会撤销已经成功的更新。",
            "Confirmed \(originalCount - remaining.count) updated; \(remaining.count) drafts retained.\n\(identity)\n\(reason)\nSubsequent updates stopped and cannot be retried directly. Reload discards the remaining drafts and reads server state; Discard All also cannot undo successful updates."
        )
        // Use a separately owned recovery task because the submission task may already be cancelled.
        documentDeletionRecoveryTask = Task { @MainActor in
            await reloadDataAfterPendingChanges()
        }
        await documentDeletionRecoveryTask?.value
        guard documentSubmissionID == submissionID else { return }
        documentDeletionRecoveryTask = nil
        showsDocumentConflict = true
    }

    private func reloadDocumentAfterConflict() {
        guard documentDeletionRecoveryTask == nil, !isSubmittingPendingChanges else { return }
        let hasCreations = documentInspectorModel.isCreating
        let reference = documentInspectorModel.preparedDeletion?
            .draft.reference
            ?? documentInspectorModel.cellChanges.order.first
            ?? documentInspectorModel.loadedSnapshot?.reference
        guard hasCreations || reference != nil else { return }
        let recoveryID = UUID()
        documentSubmissionID = recoveryID
        isSubmittingPendingChanges = true
        documentDeletionRecoveryTask = Task { @MainActor in
            defer {
                if documentSubmissionID == recoveryID {
                    documentDeletionRecoveryTask = nil
                    documentSubmissionID = nil
                    isSubmittingPendingChanges = false
                }
            }
            if hasCreations {
                documentInspectorModel.discardChanges()
                rowInsertEditor.dismiss()
                documentCreationFailureMessage = nil
                await reloadDataAfterPendingChanges()
                selectedDataRowIndexes = []
            } else if let reference {
                await reloadAuthoritativeDocument(reference, discardingDraft: true)
            }
        }
    }

    private func reloadAuthoritativeDocument(
        _ reference: WorkspaceDocumentReference,
        discardingDraft: Bool
    ) async {
        if discardingDraft {
            documentCellEditingLifetime.finish(commit: false)
            documentCellFailureMessage = nil
            documentInlineEditSnapshot = nil
            pendingInspectorUpdates.removeAll(keepingCapacity: false)
            documentInspectorModel.discardChanges()
        }
        await reloadDataAfterPendingChanges()
        restoreDocumentSelection(reference)
        guard selectedDocumentReference == reference else { return }
        await documentInspectorModel.load(reference: reference) { reference in
            try await model.fetchDocument(reference)
        }
    }

    private func restoreDocumentSelection(
        _ reference: WorkspaceDocumentReference
    ) {
        guard let page = model.selectedObjectDataState.page,
              let idColumn = page.columns.first(where: { $0.name == "_id" }),
              let indexColumn = page.columns.first(where: { $0.name == "_index" })
        else {
            selectedDataRowIndexes = []
            return
        }
        let routingColumn = page.columns.first(where: { $0.name == "_routing" })
        let match = (0..<page.rowCount).first { rowIndex in
            guard let row = page.row(at: rowIndex),
                  case .text(let id) = row.value(at: idColumn.id),
                  id == reference.id,
                  case .text(let index) = row.value(at: indexColumn.id),
                  index == reference.index
            else { return false }
            let routing: String?
            if let routingColumn,
               case .text(let value) = row.value(at: routingColumn.id) {
                routing = value
            } else {
                routing = nil
            }
            return routing == reference.routing
        }
        selectedDataRowIndexes = match.map(IndexSet.init(integer:)) ?? []
    }

    private func presentDocumentCommitError(_ message: String) {
        documentCommitErrorMessage = message
        showsDocumentCommitError = true
    }

}
