import Foundation
import QueryCraftFeature

struct PostgreSQLCQueryResult: Sendable, Equatable {
    struct ColumnOrigin: Sendable, Equatable {
        let schemaName: String
        let tableName: String
        let columnName: String
    }

    let columns: [String]
    let columnTypes: [String?]
    let columnOrigins: [ColumnOrigin?]
    let rows: [[String?]]
    let affectedRows: Int

    init(
        columns: [String] = [],
        columnTypes: [String?] = [],
        columnOrigins: [ColumnOrigin?] = [],
        rows: [[String?]] = [],
        affectedRows: Int = 0
    ) {
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnOrigins = columnOrigins
        self.rows = rows
        self.affectedRows = affectedRows
    }
}

struct PostgreSQLClientError: LocalizedError, Sendable {
    let message: String
    let sqlState: String?

    var errorDescription: String? {
        if let sqlState, !sqlState.isEmpty {
            return "\(message) [\(sqlState)]"
        }
        return message
    }
}

extension PostgreSQLCQueryResult {
    var workspaceColumns: [WorkspaceDatabaseDataColumn] {
        columns.enumerated().map { index, name in
            let origin = (columnOrigins.indices.contains(index) ? columnOrigins[index] : nil).map {
                WorkspaceDatabaseDataColumn.Origin(
                    schemaName: $0.schemaName, tableName: $0.tableName, columnName: $0.columnName
                )
            }
            return WorkspaceDatabaseDataColumn(
                id: index, name: name,
                type: columnTypes.indices.contains(index) ? columnTypes[index] : nil,
                origin: origin
            )
        }
    }

    var dictionaryRows: [[String: String?]] {
        rows.map { row in
            Dictionary(
                uniqueKeysWithValues: columns.enumerated().map {
                    index,
                    column in
                    (column, row.indices.contains(index) ? row[index] : nil)
                }
            )
        }
    }
}
