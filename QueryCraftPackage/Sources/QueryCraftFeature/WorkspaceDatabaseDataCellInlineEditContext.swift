import Foundation

struct WorkspaceDatabaseDataCellInlineEditContext: Equatable, Sendable {
    let rowIndex: Int
    let dataColumnIndex: Int
    let columnName: String
    let initialText: String
    let initialMutation: WorkspaceDatabaseInspectorMutation
    let placeholderText: String?
    let editingLifetime: WorkspaceDataCellEditingLifetime?
    let editingRevision: UUID?

    init(
        rowIndex: Int,
        dataColumnIndex: Int,
        columnName: String,
        initialText: String,
        initialMutation: WorkspaceDatabaseInspectorMutation,
        placeholderText: String? = nil,
        editingLifetime: WorkspaceDataCellEditingLifetime? = nil,
        editingRevision: UUID? = nil
    ) {
        self.rowIndex = rowIndex
        self.dataColumnIndex = dataColumnIndex
        self.columnName = columnName
        self.initialText = initialText
        self.initialMutation = initialMutation
        self.placeholderText = placeholderText
        self.editingLifetime = editingLifetime
        self.editingRevision = editingRevision
    }
}
