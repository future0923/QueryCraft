import SwiftUI

struct WorkspaceQueryDocumentContainer: View {
    @Bindable var model: WorkspaceModel
    @Bindable var document: WorkspaceQueryDocumentModel
    let editorContext: WorkspaceQueryEditorContext
    let pendingChangesRegistry: WorkspacePendingChangesRegistry
    let inspectorRegistry: WorkspaceInspectorRegistry

    var body: some View {
        WorkspaceQueryDocumentView(
            document: document,
            databases: model.databases.map(\.name),
            schemaCatalog: model.schemaCatalog,
            safetyLock: model.safetyLock,
            editorContext: editorContext,
            contentID: contentID,
            pendingChangesRegistry: pendingChangesRegistry,
            fetchResultDetails: { selection in
                try await model.fetchQueryResultDetails(
                    for: selection,
                    configuration: document.currentConnectionConfiguration
                )
            },
            applyResultChanges: { changes in
                try await model.applyQueryResultDataChanges(
                    changes,
                    configuration: document.currentConnectionConfiguration
                )
            },
            updateResultInspectorContext: publishInspectorContext
        )
        .onAppear {
            publishInspectorContext(.empty)
        }
        .onDisappear {
            pendingChangesRegistry.remove(for: contentID)
            inspectorRegistry.remove(for: contentID)
        }
    }

    private var contentID: WorkspaceContentTabID {
        .queryDocument(document.id)
    }

    private func publishInspectorContext(
        _ context: WorkspaceQueryResultInspectorContext
    ) {
        inspectorRegistry.update(.queryResult(context), for: contentID)
    }
}
