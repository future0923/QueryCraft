import Foundation

struct WorkspaceQueryDocumentCloseSnapshot: Equatable, Sendable {
    let sql: String
    let databaseName: String?
}

enum WorkspaceQueryDocumentCloseAuthorization: Equatable, Sendable {
    case preservingChanges
    case discardingChanges(WorkspaceQueryDocumentCloseSnapshot)

    @MainActor
    static func discardingCurrentChanges(
        in document: WorkspaceQueryDocumentModel
    ) -> Self {
        .discardingChanges(
            WorkspaceQueryDocumentCloseSnapshot(
                sql: document.sql,
                databaseName: document.databaseName
            )
        )
    }

    @MainActor
    func permitsClosing(_ document: WorkspaceQueryDocumentModel) -> Bool {
        guard document.isDirty else { return true }
        guard case let .discardingChanges(snapshot) = self else {
            return false
        }
        return snapshot == WorkspaceQueryDocumentCloseSnapshot(
            sql: document.sql,
            databaseName: document.databaseName
        )
    }
}
