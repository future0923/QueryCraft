import Foundation

struct PostgreSQLCQueryResult: Sendable, Equatable {
    struct ColumnOrigin: Sendable, Equatable {
        let schemaName: String
        let tableName: String
        let columnName: String
    }

    let columns: [String]
    let columnOrigins: [ColumnOrigin?]
    let rows: [[String?]]
    let affectedRows: Int

    init(
        columns: [String] = [],
        columnOrigins: [ColumnOrigin?] = [],
        rows: [[String?]] = [],
        affectedRows: Int = 0
    ) {
        self.columns = columns
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
