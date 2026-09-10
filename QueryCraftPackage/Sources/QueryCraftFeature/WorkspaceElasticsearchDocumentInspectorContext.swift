import Foundation

struct WorkspaceElasticsearchDocumentInspectorContext: Equatable {
    let selection: WorkspaceDatabaseObjectSelection
    let reference: WorkspaceDocumentReference?
    let model: WorkspaceElasticsearchDocumentInspectorModel
    let beginEditing: @MainActor () -> Void
    let updateDraft: @MainActor (String) -> Void
    let updateCreationDraft: @MainActor (String, String, String) -> Void
    let endEditing: @MainActor () -> Void
    var isReadOnly = false

    static func == (
        lhs: WorkspaceElasticsearchDocumentInspectorContext,
        rhs: WorkspaceElasticsearchDocumentInspectorContext
    ) -> Bool {
        lhs.selection == rhs.selection
            && lhs.reference == rhs.reference
            && lhs.model === rhs.model
            && lhs.isReadOnly == rhs.isReadOnly
    }
}
