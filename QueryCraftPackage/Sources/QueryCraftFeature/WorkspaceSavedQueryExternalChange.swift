enum WorkspaceSavedQueryExternalChange {
    case changed(
        document: WorkspaceQueryDocumentModel,
        query: SavedQuery
    )
    case deleted(document: WorkspaceQueryDocumentModel)
}
