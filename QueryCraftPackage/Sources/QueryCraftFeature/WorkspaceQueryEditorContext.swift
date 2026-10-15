import Foundation

@MainActor
final class WorkspaceQueryEditorContext {
    let languageService: WorkspaceSQLLanguageService
    let commandCoordinator: WorkspaceQueryEditorCommandCoordinator
    let completionService: WorkspaceSQLCompletionService

    init(
        document: WorkspaceQueryDocumentModel,
        schemaCatalog: WorkspaceSchemaCatalogSnapshot,
        prepareCompletionColumns: @escaping @MainActor (
            [WorkspaceSchemaObjectReference]
        ) async -> WorkspaceSchemaCatalogSnapshot,
        save: (@MainActor () -> Void)? = nil
    ) {
        let languageService = WorkspaceSQLLanguageService(context: .init(databaseType: document.databaseType))
        let snippetSession = SQLSnippetSession()
        self.languageService = languageService
        commandCoordinator = WorkspaceQueryEditorCommandCoordinator(
            document: document,
            languageService: languageService,
            snippetSession: snippetSession,
            save: save
        )
        completionService = WorkspaceSQLCompletionService(
            languageService: languageService,
            schemaCatalog: schemaCatalog,
            defaultDatabase: { document.databaseName },
            prepareCompletionColumns: prepareCompletionColumns,
            databaseType: { document.databaseType },
            snippetSession: snippetSession
        )
    }
}
