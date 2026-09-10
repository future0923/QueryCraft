import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class WorkspaceNewTableDraft: Identifiable {
    let id: UUID
    let databaseName: String
    let schemaName: String?
    let schemaEditingDescriptor: WorkspaceDatabaseSchemaEditingDescriptor
    var tableName = ""
    var editor: WorkspaceDatabaseSchemaEditorState
    var options = WorkspaceDatabaseTableOptions()
    var selectedTab = WorkspaceDatabaseObjectDetailTab.structure
    var selectedColumnID: UUID?
    var selectedIndexID: UUID?

    private let didCreate: @MainActor (
        UUID,
        WorkspaceDatabaseObjectSelection
    ) -> Void

    init(
        id: UUID = UUID(),
        databaseName: String,
        schemaName: String? = nil,
        schemaEditingDescriptor: WorkspaceDatabaseSchemaEditingDescriptor =
            .unavailable,
        didCreate: @escaping @MainActor (
            UUID,
            WorkspaceDatabaseObjectSelection
        ) -> Void = { _, _ in }
    ) {
        self.id = id
        self.databaseName = databaseName
        self.schemaName = schemaName
        self.schemaEditingDescriptor = schemaEditingDescriptor
        self.didCreate = didCreate
        var editor = WorkspaceDatabaseSchemaEditorState()
        let initialColumnType = schemaEditingDescriptor.defaultColumnType.isEmpty
            ? "VARCHAR(255)"
            : schemaEditingDescriptor.defaultColumnType
        let firstColumnID = editor.addColumn(defaultType: initialColumnType)
        self.editor = editor
        selectedColumnID = firstColumnID
    }

    var title: String {
        let name = tableName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? AppCopy.current.text("新增表", "New Table")
            : name
    }

    var mutation: WorkspaceDatabaseTableMutation {
        .create(
            databaseName: databaseName,
            tableName: schemaName.map { "\($0).\(tableName)" } ?? tableName,
            columns: editor.columns,
            indexes: editor.indexes,
            options: options
        )
    }

    var availableTabs: [WorkspaceDatabaseObjectDetailTab] {
        schemaEditingDescriptor == .unavailable
            || schemaEditingDescriptor.supportsTableOptions
            ? [.structure, .indexes, .options]
            : [.structure, .indexes]
    }

    func reset() {
        let schemaChoices = editor.schemaChoices
        tableName = ""
        editor = WorkspaceDatabaseSchemaEditorState()
        editor.updateSchemaChoices(schemaChoices)
        options = WorkspaceDatabaseTableOptions()
        selectedColumnID = editor.addColumn(defaultType: defaultColumnType)
        selectedIndexID = nil
        selectedTab = .structure
    }

    private var defaultColumnType: String {
        schemaEditingDescriptor.defaultColumnType.isEmpty
            ? "VARCHAR(255)"
            : schemaEditingDescriptor.defaultColumnType
    }

    var defaultIndexMethod: String {
        schemaEditingDescriptor.indexMethods.first ?? "BTREE"
    }

    func complete(with selection: WorkspaceDatabaseObjectSelection) {
        didCreate(id, selection)
    }
}

struct WorkspaceNewTableDetailView: View {
    @Bindable var draft: WorkspaceNewTableDraft
    let model: WorkspaceModel
    let pendingChangesRegistry: WorkspacePendingChangesRegistry
    let inspectorRegistry: WorkspaceInspectorRegistry

    @State private var showsSafetyLockConfirmation = false
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var schemaChoicesTask: Task<Void, Never>?
    @State private var pendingExecutionPlan: WorkspaceDatabaseSchemaExecutionPlan?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch draft.selectedTab {
                case .structure:
                    WorkspaceDatabaseStructureView(
                        columns: draft.editor.columns,
                        descriptor: draft.schemaEditingDescriptor,
                        schemaChoices: draft.editor.schemaChoices,
                        selection: $draft.selectedColumnID,
                        isEditable: !isSubmitting,
                        add: addColumn,
                        duplicate: duplicateColumn,
                        update: updateColumn,
                        primaryKeyColumnIDs: primaryKeyColumnIDs,
                        setPrimaryKey: setPrimaryKey,
                        delete: deleteColumn
                    )

                case .indexes:
                    WorkspaceDatabaseIndexesView(
                        state: .loaded([]),
                        indexes: draft.editor.indexes,
                        descriptor: draft.schemaEditingDescriptor,
                        availableColumnNames: availableColumnNames,
                        selection: $draft.selectedIndexID,
                        retry: {},
                        isEditable: !isSubmitting,
                        add: addIndex,
                        duplicate: duplicateIndex,
                        update: updateIndex,
                        delete: deleteIndex
                    )

                case .options:
                    WorkspaceNewTableOptionsView(
                        tableName: $draft.tableName,
                        options: $draft.options,
                        schemaChoices: draft.editor.schemaChoices,
                        isDisabled: isSubmitting
                    )

                case .data, .ddl:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 8) {
                Picker(
                    AppCopy.current.text("表定义", "Table Definition"),
                    selection: $draft.selectedTab
                ) {
                    ForEach(draft.availableTabs) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("newTableDefinitionTabPicker")

                if draft.selectedTab != .options {
                    Button(
                        draft.selectedTab == .structure
                            ? AppCopy.current.text("字段", "Column")
                            : AppCopy.current.text("索引", "Index"),
                        systemImage: "plus",
                        action: addSelectedItem
                    )
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(isSubmitting)
                    .help(
                        draft.selectedTab == .structure
                            ? AppCopy.current.text("新增字段", "Add Column")
                            : AppCopy.current.text("新增索引", "Add Index")
                    )
                    .accessibilityIdentifier("newTableAddDefinitionButton")
                }

                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
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
                actions: nil,
                filterPresentationActions: nil,
                objectDetailTabActions: objectDetailTabActions,
                isSuspended: isSubmitting,
                schemaActions: schemaRowCommandActions
            )
        }
        .alert(
            AppCopy.current.text("停用安全锁？", "Disable Safety Lock?"),
            isPresented: $showsSafetyLockConfirmation
        ) {
            Button(
                AppCopy.current.text(
                    "允许此工作区进行更改",
                    "Allow Changes for This Workspace"
                ),
                role: .destructive
            ) {
                model.safetyLock.disable()
                submit()
            }
            .keyboardShortcut(.defaultAction)
            Button(AppCopy.current.text("取消", "Cancel"), role: .cancel) {}
                .keyboardShortcut(.cancelAction)
        } message: {
            Text(
                AppCopy.current.text(
                    "创建表会更改数据库结构。安全锁将保持停用，直到此工作区关闭。",
                    "Creating a table changes the database structure. Safety Lock will remain disabled until this workspace closes."
                )
            )
        }
        .alert(
            AppCopy.current.text("无法创建表", "Unable to Create Table"),
            isPresented: errorPresentation
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            loadSchemaChoices()
            publishPendingChangesActions()
            publishInspectorContext()
        }
        .onChange(of: pendingChangesActions) { _, _ in
            publishPendingChangesActions()
        }
        .onChange(of: schemaInspectorContext) { _, _ in
            publishInspectorContext()
        }
        .onDisappear {
            schemaChoicesTask?.cancel()
            submissionTask?.cancel()
            pendingChangesRegistry.remove(for: contentID)
            inspectorRegistry.remove(for: contentID)
        }
    }

    private var contentID: WorkspaceContentTabID { .newTable(draft.id) }

    private var isSubmitting: Bool { submissionTask != nil }

    private var availableColumnNames: [String] {
        draft.editor.columns
            .filter { !$0.isDeleted }
            .map(\.definition.name)
            .filter { !$0.isEmpty }
    }

    private var primaryKeyColumnIDs: Set<UUID> {
        Set(draft.editor.columns.compactMap { item in
            draft.editor.isPrimaryKey(columnID: item.id) ? item.id : nil
        })
    }

    private var pendingChangesActions: WorkspacePendingChangesActions {
        let plan = try? model.schemaExecutionPlan(for: draft.mutation)
        return WorkspacePendingChangesActions(
            hasChanges: true,
            statements: plan.map {
                WorkspaceSQLPreviewStatement.make(schemaExecutionPlan: $0)
            } ?? [],
            isCommitting: isSubmitting,
            discard: discardChanges,
            preview: {},
            commit: { requestSubmit(executionPlan: plan) }
        )
    }

    private var schemaInspectorContext: WorkspaceDatabaseSchemaInspectorContext? {
        switch draft.selectedTab {
        case .structure:
            guard
                let selectedColumnID = draft.selectedColumnID,
                let item = draft.editor.columns.first(where: {
                    $0.id == selectedColumnID
                })
            else { return nil }
            return WorkspaceDatabaseSchemaInspectorContext(
                item: .column(item),
                descriptor: draft.schemaEditingDescriptor,
                availableColumnNames: availableColumnNames,
                schemaChoices: draft.editor.schemaChoices,
                isPrimaryKey: draft.editor.isPrimaryKey(columnID: item.id),
                setPrimaryKey: setPrimaryKey,
                updateColumn: updateColumn,
                updateIndex: updateIndex
            )
        case .indexes:
            guard
                let selectedIndexID = draft.selectedIndexID,
                let item = draft.editor.indexes.first(where: {
                    $0.id == selectedIndexID
                })
            else { return nil }
            return WorkspaceDatabaseSchemaInspectorContext(
                item: .index(item),
                descriptor: draft.schemaEditingDescriptor,
                availableColumnNames: availableColumnNames,
                schemaChoices: draft.editor.schemaChoices,
                isPrimaryKey: false,
                setPrimaryKey: setPrimaryKey,
                updateColumn: updateColumn,
                updateIndex: updateIndex
            )
        case .data, .options, .ddl:
            return nil
        }
    }

    private var schemaRowCommandActions: WorkspaceDatabaseSchemaRowCommandActions {
        switch draft.selectedTab {
        case .indexes:
            let selectedItem = draft.selectedIndexID.flatMap { id in
                draft.editor.indexes.first(where: { $0.id == id })
            }
            return WorkspaceDatabaseSchemaRowCommandActions(
                kind: .index,
                selectedID: draft.selectedIndexID,
                canAdd: !isSubmitting,
                canDuplicate: !isSubmitting && selectedItem?.isDeleted == false,
                canDelete: !isSubmitting && selectedItem?.isDeleted == false,
                add: addIndex,
                duplicate: duplicateIndex,
                delete: deleteIndex
            )
        case .structure, .data, .ddl:
            let selectedItem = draft.selectedColumnID.flatMap { id in
                draft.editor.columns.first(where: { $0.id == id })
            }
            return WorkspaceDatabaseSchemaRowCommandActions(
                kind: .column,
                selectedID: draft.selectedColumnID,
                canAdd: !isSubmitting,
                canDuplicate: !isSubmitting && selectedItem?.isDeleted == false,
                canDelete: !isSubmitting && selectedItem?.isDeleted == false,
                add: addColumn,
                duplicate: duplicateColumn,
                delete: deleteColumn
            )
        case .options:
            return WorkspaceDatabaseSchemaRowCommandActions(
                kind: .column,
                selectedID: nil,
                canAdd: false,
                canDuplicate: false,
                canDelete: false,
                add: {},
                duplicate: { _ in },
                delete: { _ in }
            )
        }
    }

    private var objectDetailTabActions:
        WorkspaceDatabaseObjectDetailTabActions
    {
        WorkspaceDatabaseObjectDetailTabActions(
            availableTabs: draft.availableTabs,
            select: { tab in
                draft.selectedTab = tab
            }
        )
    }

    private var errorPresentation: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { isPresented in
                if !isPresented { errorMessage = nil }
            }
        )
    }

    private func publishPendingChangesActions() {
        pendingChangesRegistry.update(pendingChangesActions, for: contentID)
    }

    private func loadSchemaChoices() {
        guard schemaChoicesTask == nil else { return }
        schemaChoicesTask = Task { @MainActor in
            let choices = await model.loadSchemaChoices()
            guard !Task.isCancelled else { return }
            draft.editor.updateSchemaChoices(choices)
            schemaChoicesTask = nil
        }
    }

    private func publishInspectorContext() {
        guard let schemaInspectorContext else {
            inspectorRegistry.remove(for: contentID)
            return
        }
        inspectorRegistry.update(
            .schemaDraft(draft.id, schemaInspectorContext),
            for: contentID
        )
    }

    private func discardChanges() {
        guard !isSubmitting else { return }
        pendingExecutionPlan = nil
        draft.reset()
    }

    private func requestSubmit() {
        requestSubmit(
            executionPlan: try? model.schemaExecutionPlan(for: draft.mutation)
        )
    }

    private func requestSubmit(
        executionPlan: WorkspaceDatabaseSchemaExecutionPlan?
    ) {
        guard !isSubmitting else { return }
        guard let executionPlan else {
            errorMessage = AppCopy.current.text(
                "无法生成建表 SQL。",
                "Unable to generate CREATE TABLE SQL."
            )
            return
        }
        pendingExecutionPlan = executionPlan
        if model.safetyLock.isEnabled {
            showsSafetyLockConfirmation = true
        } else {
            submit()
        }
    }

    private func submit() {
        guard
            submissionTask == nil,
            let executionPlan = pendingExecutionPlan,
            case let .tableMutation(submittedMutation) = executionPlan.source
        else { return }
        submissionTask = Task { @MainActor in
            defer {
                submissionTask = nil
                pendingExecutionPlan = nil
            }
            do {
                try await model.applyTableMutation(executionPlan)
                try Task.checkCancellation()
                guard var selection = submittedMutation.resultingSelection else {
                    return
                }
                if model.databaseType == .postgresql {
                    if !selection.objectName.contains(".") {
                        selection = WorkspaceDatabaseObjectSelection(
                            databaseName: selection.databaseName,
                            objectName: "public.\(selection.objectName)",
                            kind: .table
                        )
                    }
                }
                draft.complete(with: selection)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func addSelectedItem() {
        if draft.selectedTab == .indexes {
            addIndex()
        } else {
            addColumn()
        }
    }

    private func addColumn() {
        draft.selectedColumnID = draft.editor.addColumn(
            defaultType: draft.schemaEditingDescriptor.defaultColumnType.isEmpty
                ? "VARCHAR(255)"
                : draft.schemaEditingDescriptor.defaultColumnType
        )
    }

    private func duplicateColumn(_ id: UUID) {
        draft.selectedColumnID = draft.editor.duplicateColumn(id: id)
            ?? draft.selectedColumnID
    }

    private func updateColumn(
        _ id: UUID,
        _ definition: WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) {
        draft.editor.updateColumn(id: id, definition: definition)
    }

    private func setPrimaryKey(_ id: UUID, _ isEnabled: Bool) {
        draft.editor.setPrimaryKey(columnID: id, isEnabled: isEnabled)
    }

    private func deleteColumn(_ id: UUID) {
        draft.selectedColumnID = draft.editor.deleteColumn(id: id)
    }

    private func addIndex() {
        draft.selectedIndexID = draft.editor.addIndex(
            defaultMethod: draft.defaultIndexMethod
        )
    }

    private func duplicateIndex(_ id: UUID) {
        draft.selectedIndexID = draft.editor.duplicateIndex(id: id)
            ?? draft.selectedIndexID
    }

    private func updateIndex(
        _ id: UUID,
        _ definition: WorkspaceDatabaseSchemaEditorState.IndexDefinition
    ) {
        draft.editor.updateIndex(id: id, definition: definition)
    }

    private func deleteIndex(_ id: UUID) {
        draft.selectedIndexID = draft.editor.deleteIndex(id: id)
    }
}
