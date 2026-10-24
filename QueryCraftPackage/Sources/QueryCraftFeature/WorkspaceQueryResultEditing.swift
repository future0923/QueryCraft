import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

#if !os(iOS)
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

struct WorkspaceQueryResultPendingDelete: Equatable, Sendable {
    let resultID: UUID
    let rowIndex: Int
    let pendingDelete: WorkspaceDatabaseInspectorPendingDelete

    var rowDelete: WorkspaceDatabaseDataRowDelete {
        pendingDelete.rowDelete
    }

    var replacedUpdates: [WorkspaceDatabaseInspectorPendingUpdate] {
        pendingDelete.replacedUpdates
    }
}
#endif

enum WorkspaceQueryResultEditing {
    static func selection(
        for origin: WorkspaceDatabaseDataColumn.Origin,
        currentDatabase: String?
    ) -> WorkspaceDatabaseObjectSelection? {
        guard let databaseName = origin.databaseName ?? currentDatabase,
              !databaseName.isEmpty else { return nil }
        return WorkspaceDatabaseObjectSelection(
            databaseName: databaseName,
            objectName: origin.schemaName.map { WorkspaceDatabaseObject.postgreSQLName(schema: $0, table: origin.tableName) } ?? origin.tableName,
            kind: .table
        )
    }

    #if !os(iOS)
    static func selection(
        for page: WorkspaceQueryResultPage,
        currentDatabase: String?
    ) -> WorkspaceDatabaseObjectSelection? {
        selection(for: page.columns, currentDatabase: currentDatabase)
    }
    #endif

    static func selection(for columns: [WorkspaceDatabaseDataColumn], currentDatabase: String?) -> WorkspaceDatabaseObjectSelection? {
        let origins = columns.compactMap(\.origin)
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
            WorkspaceDatabaseObject.postgreSQLName(schema: $0, table: identity.tableName)
        } ?? identity.tableName
        return WorkspaceDatabaseObjectSelection(
            databaseName: databaseName,
            objectName: objectName,
            kind: .table
        )
    }

    /// Query expressions cannot supply physical key values just by being named
    /// `id`. Reject ambiguous projected keys before ordinary request preparation.
    static func validatedColumns(selection: WorkspaceDatabaseObjectSelection,
                                 columns: [WorkspaceDatabaseDataColumn], row: WorkspaceDatabaseDataRow,
                                 metadata: [WorkspaceDatabaseColumn]) throws -> [WorkspaceDatabaseDataColumn] {
        let source = self.selection(for: columns, currentDatabase: selection.databaseName)
        let exact = source == selection
        let physical = columns.first(where: { $0.origin != nil })?.origin
        guard exact || (source != nil && physical?.schemaName != nil
            && source?.databaseName == selection.databaseName
            && physical?.schemaName == selection.object.schemaName
            && physical?.tableName == selection.object.nameWithinSchema) else {
            throw WorkspaceDatabaseDataCellEditError.metadataUnavailable
        }
        for key in metadata where key.key.uppercased() == "PRI" {
            let matches = columns.filter { $0.origin?.columnName == key.name }
            guard let first = matches.first, row.value(at: first.id) != .null,
                  matches.allSatisfy({ row.value(at: $0.id) == row.value(at: first.id) }) else {
                throw WorkspaceDatabaseDataCellEditError.primaryKeyValueUnavailable(key.name)
            }
        }
        // Preserve IDs/order/aliases for native inline editing; nil-origin names
        // are blank only inside request preparation, never in displayed metadata.
        return columns.map { column in
            column.origin == nil ? .init(id: column.id, name: "", type: column.type) : column
        }
    }

    static func editTarget(selection: WorkspaceDatabaseObjectSelection,
                           target: WorkspaceDatabaseDataCellEditTarget,
                           metadata: [WorkspaceDatabaseColumn]) throws -> WorkspaceDatabaseDataCellEditTarget {
        guard target.column?.origin != nil else { throw WorkspaceDatabaseDataCellEditError.metadataUnavailable }
        return .init(rowIndex: target.rowIndex, dataColumnIndex: target.dataColumnIndex,
                     columns: try validatedColumns(selection: selection, columns: target.columns, row: target.row, metadata: metadata), row: target.row)
    }

    static func deleteRequest(selection: WorkspaceDatabaseObjectSelection, row: WorkspaceDatabaseDataRow,
                              columns: [WorkspaceDatabaseDataColumn], metadata: [WorkspaceDatabaseColumn]) throws -> WorkspaceDatabaseDataRowDelete {
        try WorkspaceDatabaseDataRowDeleteRequest.make(selection: selection, row: row,
            columns: validatedColumns(selection: selection, columns: columns, row: row, metadata: metadata), metadata: metadata)
    }

    private struct Identity: Hashable {
        let databaseName: String?
        let schemaName: String?
        let tableName: String
    }
}
