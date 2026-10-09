import Foundation

struct WorkspaceDatabaseDataCellInlineEditContext: Equatable, Sendable {
    let rowIndex: Int
    let dataColumnIndex: Int
    let columnName: String
    let initialText: String
    let initialMutation: WorkspaceDatabaseInspectorMutation
    let columnType: String?
    let isNullable: Bool
    let placeholderText: String?
    let editingLifetime: WorkspaceDataCellEditingLifetime?
    let editingRevision: UUID?

    init(
        rowIndex: Int,
        dataColumnIndex: Int,
        columnName: String,
        initialText: String,
        initialMutation: WorkspaceDatabaseInspectorMutation,
        columnType: String? = nil,
        isNullable: Bool = false,
        placeholderText: String? = nil,
        editingLifetime: WorkspaceDataCellEditingLifetime? = nil,
        editingRevision: UUID? = nil
    ) {
        self.rowIndex = rowIndex
        self.dataColumnIndex = dataColumnIndex
        self.columnName = columnName
        self.initialText = initialText
        self.initialMutation = initialMutation
        self.columnType = columnType
        self.isNullable = isNullable
        self.placeholderText = placeholderText
        self.editingLifetime = editingLifetime
        self.editingRevision = editingRevision
    }
}
