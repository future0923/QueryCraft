import Foundation

struct WorkspaceDatabaseContextRestorationState:
    Codable,
    Equatable,
    Identifiable,
    Sendable
{
    let id: UUID
    let databaseName: String?
    let selectedObject: WorkspaceDatabaseObjectSelection?
    let queryDocuments: [WorkspaceQueryDocumentRestorationState]
    let selectedQueryDocumentID: UUID?
    let contentTabOrder: [WorkspaceContentTabID]
    let selectedContentTab: WorkspaceContentTabID?
    let sidebarMode: WorkspaceSidebarMode
    let elasticsearchRequestDocuments:
        [WorkspaceElasticsearchRequestRestorationState]?

    init(
        id: UUID,
        databaseName: String?,
        selectedObject: WorkspaceDatabaseObjectSelection?,
        queryDocuments: [WorkspaceQueryDocumentRestorationState],
        selectedQueryDocumentID: UUID?,
        contentTabOrder: [WorkspaceContentTabID],
        selectedContentTab: WorkspaceContentTabID?,
        sidebarMode: WorkspaceSidebarMode,
        elasticsearchRequestDocuments:
            [WorkspaceElasticsearchRequestRestorationState]? = nil
    ) {
        self.id = id
        self.databaseName = databaseName
        self.selectedObject = selectedObject
        self.queryDocuments = queryDocuments
        self.selectedQueryDocumentID = selectedQueryDocumentID
        self.contentTabOrder = contentTabOrder
        self.selectedContentTab = selectedContentTab
        self.sidebarMode = sidebarMode
        self.elasticsearchRequestDocuments = elasticsearchRequestDocuments
    }
}
