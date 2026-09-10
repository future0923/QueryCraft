import Foundation

struct WorkspaceQueryTabItem: Identifiable {
    let document: WorkspaceQueryDocumentModel
    let editorContext: WorkspaceQueryEditorContext

    var id: UUID {
        document.id
    }
}
