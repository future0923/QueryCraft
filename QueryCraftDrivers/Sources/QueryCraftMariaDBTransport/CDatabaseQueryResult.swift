import Foundation
import QueryCraftFeature

package struct CDatabaseQueryResult: Sendable, Equatable {
    package struct ColumnOrigin: Sendable, Equatable {
        package let databaseName: String
        package let tableName: String
        package let columnName: String

        package init(
            databaseName: String,
            tableName: String,
            columnName: String
        ) {
            self.databaseName = databaseName
            self.tableName = tableName
            self.columnName = columnName
        }
    }

    package let columns: [String]
    package let columnTypes: [String?]
    package let columnOrigins: [ColumnOrigin?]
    package let rows: [[String?]]
    package let affectedRows: UInt64
    package let insertID: UInt64

    package init(
        columns: [String] = [],
        columnTypes: [String?] = [],
        columnOrigins: [ColumnOrigin?] = [],
        rows: [[String?]] = [],
        affectedRows: UInt64 = 0,
        insertID: UInt64 = 0
    ) {
        self.columns = columns
        self.columnTypes = columnTypes
        self.columnOrigins = columnOrigins
        self.rows = rows
        self.affectedRows = affectedRows
        self.insertID = insertID
    }
}

package struct CDatabaseClientError: LocalizedError, Sendable {
    package let code: UInt32
    package let message: String
    package let sqlState: String?

    package var errorDescription: String? {
        if let sqlState, !sqlState.isEmpty {
            return "\(message) [\(sqlState)]"
        }
        return message
    }
}

package extension CDatabaseQueryResult {
    var workspaceColumns: [WorkspaceDatabaseDataColumn] {
        columns.enumerated().map { index, name in
            let origin = (columnOrigins.indices.contains(index) ? columnOrigins[index] : nil).map {
                WorkspaceDatabaseDataColumn.Origin(
                    databaseName: $0.databaseName, tableName: $0.tableName, columnName: $0.columnName
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
