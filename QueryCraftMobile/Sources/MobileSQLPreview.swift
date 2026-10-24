import QueryCraftMobileCore
import QueryCraftMobileTransport

/// Preserve each protocol's physical metadata without changing the desktop ABI.
struct MobileSQLPreview: Sendable {
    let result: CDatabaseQueryResult
    let cells: [[WorkspaceDatabaseDataCell]]
    let isTruncated: Bool
    var columnDetails: [String]? = nil
    let metadata: [WorkspaceDatabaseDataColumn]?
    var workspaceColumns: [WorkspaceDatabaseDataColumn] { metadata ?? result.workspaceColumns }
    init(result: CDatabaseQueryResult, cells: [[WorkspaceDatabaseDataCell]] = [], isTruncated: Bool = false,
         metadata: [WorkspaceDatabaseDataColumn]? = nil) {
        self.result = result; self.cells = cells; self.isTruncated = isTruncated; self.metadata = metadata
    }
    init(_ preview: CDatabaseQueryPreview) {
        self.init(result: preview.result, cells: preview.cells, isTruncated: preview.isTruncated)
    }
    init(postgreSQL preview: PostgreSQLQueryPreview, database: String) {
        let result = preview.result
        self.init(result: .init(columns: result.columns, columnTypes: result.columnTypes,
            rows: result.rows, affectedRows: UInt64(max(0, result.affectedRows))),
            cells: result.rows.map { $0.map { $0.map(WorkspaceDatabaseDataCell.text) ?? .null } },
            isTruncated: preview.isTruncated,
            metadata: result.workspaceColumns.map { column in
                .init(id: column.id, name: column.name, type: column.type, origin: column.origin.map {
                    .init(databaseName: database, schemaName: $0.schemaName, tableName: $0.tableName, columnName: $0.columnName)
                })
            })
    }
}
