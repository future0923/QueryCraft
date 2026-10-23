import Foundation
import Observation
#if os(iOS)
import QueryCraftMobileCore
#endif

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
