import Foundation

struct WorkspaceDatabaseSchemaInspectorContext: Equatable {
    enum Item: Equatable {
        case column(WorkspaceDatabaseSchemaEditorState.ColumnItem)
        case index(WorkspaceDatabaseSchemaEditorState.IndexItem)
    }

    let item: Item
    let descriptor: WorkspaceDatabaseSchemaEditingDescriptor
    let availableColumnNames: [String]
    let schemaChoices: WorkspaceDatabaseSchemaChoices
    let isPrimaryKey: Bool
    let setPrimaryKey: @MainActor (UUID, Bool) -> Void
    let updateColumn: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.ColumnDefinition
    ) -> Void
    let updateIndex: @MainActor (
        UUID,
        WorkspaceDatabaseSchemaEditorState.IndexDefinition
    ) -> Void

    static func == (
        lhs: WorkspaceDatabaseSchemaInspectorContext,
        rhs: WorkspaceDatabaseSchemaInspectorContext
    ) -> Bool {
        lhs.item == rhs.item
            && lhs.descriptor == rhs.descriptor
            && lhs.availableColumnNames == rhs.availableColumnNames
            && lhs.schemaChoices == rhs.schemaChoices
            && lhs.isPrimaryKey == rhs.isPrimaryKey
    }
}
