import Foundation

struct WorkspaceQueryResultInsertDraft: Identifiable {
    let id = UUID()
    let resultID: UUID
    let editor: WorkspaceDatabaseDataRowInsertEditorState
}
