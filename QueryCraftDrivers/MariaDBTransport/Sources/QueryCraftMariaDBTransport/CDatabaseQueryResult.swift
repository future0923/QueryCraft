import Foundation
import QueryCraftFeature

public struct CDatabaseQueryResult: Sendable, Equatable {
    public struct ColumnOrigin: Sendable, Equatable {
        public let databaseName: String
        public let tableName: String
        public let columnName: String

        public init(
            databaseName: String,
            tableName: String,
            columnName: String
        ) {
            self.databaseName = databaseName
            self.tableName = tableName
            self.columnName = columnName
        }
    }

    public let columns: [String]
    public let columnTypes: [String?]
    public let columnOrigins: [ColumnOrigin?]
    public let rows: [[String?]]
    public let affectedRows: UInt64
    public let insertID: UInt64

    public init(
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

public struct CDatabaseClientError: LocalizedError, Sendable {
    public let code: UInt32
    public let message: String
    public let sqlState: String?

    public var errorDescription: String? {
        if let sqlState, !sqlState.isEmpty {
            return "\(message) [\(sqlState)]"
        }
        return message
    }
}

public extension CDatabaseQueryResult {
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
