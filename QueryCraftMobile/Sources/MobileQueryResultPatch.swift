import Foundation
import QueryCraftMobileCore
import QueryCraftMobileTransport

/// Match the captured raw row before applying *any* key changes. Expressions
/// retain their server value until the user explicitly executes the query again.
enum MobileQueryResultPatch {
    static func apply(_ changes: WorkspaceDatabaseDataChangeSet, to preview: MobileSQLPreview) -> MobileSQLPreview {
        let source = MobileGridData(preview: preview), columns = preview.workspaceColumns
        var cells: [[WorkspaceDatabaseDataCell]] = [], rows: [[String?]] = []
        for index in source.rows.indices {
            func matches(_ conditions: [WorkspaceDatabaseDataCellUpdateCondition]) -> Bool {
                !conditions.isEmpty && conditions.allSatisfy { key in
                    guard let column = columns.first(where: { $0.origin?.columnName == key.columnName }) else { return false }
                    return source.cell(row: index, column: column.id) == key.value
                }
            }
            if changes.deletes.contains(where: { matches($0.conditions) }) { continue }
            var rowCells = columns.indices.map { source.cell(row: index, column: $0) }
            var row = source.rows[index]
            for update in changes.updates where matches(update.primaryKey) {
                for column in columns where column.origin?.columnName == update.columnName {
                    rowCells[column.id] = update.newValue
                    if row.indices.contains(column.id) {
                        switch update.newValue {
                        case .text(let value): row[column.id] = value
                        case .null: row[column.id] = nil
                        case .binary: break
                        }
                    }
                }
            }
            rows.append(row); cells.append(rowCells)
        }
        let result = CDatabaseQueryResult(columns: preview.result.columns, columnTypes: preview.result.columnTypes,
            columnOrigins: preview.result.columnOrigins, rows: rows, affectedRows: preview.result.affectedRows, insertID: preview.result.insertID)
        return .init(result: result, cells: cells, isTruncated: preview.isTruncated, metadata: preview.metadata)
    }
}
