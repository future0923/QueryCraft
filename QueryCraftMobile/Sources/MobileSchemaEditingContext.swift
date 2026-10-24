import Foundation

/// The native forms edit the same shared definitions for existing and new tables.
@MainActor struct MobileSchemaEditingContext {
    var readDescriptor: () -> WorkspaceDatabaseSchemaEditingDescriptor = { MySQLSchemaEditingProvider().descriptor }
    var descriptor: WorkspaceDatabaseSchemaEditingDescriptor { readDescriptor() }
    var readState: () -> WorkspaceDatabaseSchemaEditorState
    var readEpoch: () -> UUID
    var allowsEditing: () -> Bool
    var updateColumn: (UUID, WorkspaceDatabaseSchemaEditorState.ColumnDefinition, Bool) -> Void
    var updateIndex: (UUID, WorkspaceDatabaseSchemaEditorState.IndexDefinition) -> Void
    var delete: (UUID) -> Void
    var state: WorkspaceDatabaseSchemaEditorState { readState() }
    var epoch: UUID { readEpoch() }
    var canEdit: Bool { allowsEditing() }

    init(controller: MobileSchemaController, draft: MobileSchemaDraft) {
        readDescriptor = { draft.dialect.descriptor }
        readState = { draft.state }; readEpoch = { draft.epoch }; allowsEditing = { controller.canEdit(draft) }
        updateColumn = { draft.updateColumn($0, definition: $1, primary: $2) }
        updateIndex = { draft.updateIndex($0, definition: $1) }; delete = { draft.delete($0) }
    }

    init(readState: @escaping () -> WorkspaceDatabaseSchemaEditorState, readEpoch: @escaping () -> UUID,
         allowsEditing: @escaping () -> Bool,
         updateColumn: @escaping (UUID, WorkspaceDatabaseSchemaEditorState.ColumnDefinition, Bool) -> Void,
         updateIndex: @escaping (UUID, WorkspaceDatabaseSchemaEditorState.IndexDefinition) -> Void,
         delete: @escaping (UUID) -> Void,
         readDescriptor: @escaping () -> WorkspaceDatabaseSchemaEditingDescriptor = { MySQLSchemaEditingProvider().descriptor }) {
        self.readDescriptor = readDescriptor
        self.readState = readState; self.readEpoch = readEpoch; self.allowsEditing = allowsEditing
        self.updateColumn = updateColumn; self.updateIndex = updateIndex; self.delete = delete
    }
}
