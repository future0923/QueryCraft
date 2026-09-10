import Foundation

struct WorkspaceQueryResultPendingCellUpdate: Equatable, Sendable {
    let resultID: UUID
    let rowIndex: Int
    let dataColumnIndex: Int
    let pendingUpdate: WorkspaceDatabaseInspectorPendingUpdate

    func matches(_ update: WorkspaceDatabaseDataCellUpdate) -> Bool {
        pendingUpdate.matches(update)
    }

    var mutation: WorkspaceQueryResultCellMutation {
        WorkspaceQueryResultCellMutation(
            rowIndex: rowIndex,
            dataColumnIndex: dataColumnIndex,
            value: pendingUpdate.update.newValue
        )
    }
}

enum WorkspaceQueryResultEditing {
    static func selection(
        for page: WorkspaceQueryResultPage,
        currentDatabase: String?
    ) -> WorkspaceDatabaseObjectSelection? {
        let origins = page.columns.compactMap(\.origin)
        guard !origins.isEmpty else { return nil }
        let identities = Set(origins.map { origin in
            Identity(
                databaseName: origin.databaseName ?? currentDatabase,
                schemaName: origin.schemaName,
                tableName: origin.tableName
            )
        })
        guard
            identities.count == 1,
            let identity = identities.first,
            let databaseName = identity.databaseName,
            !databaseName.isEmpty
        else {
            return nil
        }
        let objectName = identity.schemaName.map {
            "\($0).\(identity.tableName)"
        } ?? identity.tableName
        return WorkspaceDatabaseObjectSelection(
            databaseName: databaseName,
            objectName: objectName,
            kind: .table
        )
    }

    private struct Identity: Hashable {
        let databaseName: String?
        let schemaName: String?
        let tableName: String
    }
}
