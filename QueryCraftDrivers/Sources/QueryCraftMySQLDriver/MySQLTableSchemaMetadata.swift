import Foundation
#if os(iOS)
import QueryCraftMobileCore
#else
import QueryCraftFeature
#endif

/// The desktop and mobile editors consume the same complete field/index metadata.
enum MySQLTableSchemaMetadata {
    static func columnsQuery(database: String, name: String) -> String {
        return """
            SELECT
                COLUMN_NAME AS column_name,
                COLUMN_TYPE AS column_type,
                COLLATION_NAME AS collation_name,
                IS_NULLABLE AS is_nullable,
                COLUMN_KEY AS column_key,
                COLUMN_DEFAULT AS column_default,
                EXTRA AS extra,
                COLUMN_COMMENT AS column_comment,
                GENERATION_EXPRESSION AS generation_expression
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(literal(database))
                AND TABLE_NAME = \(literal(name))
            ORDER BY ORDINAL_POSITION
            """
    }
    static func columns(_ rows: [[String: String?]]) -> [WorkspaceDatabaseColumn] {
        return rows.compactMap {
            row -> WorkspaceDatabaseColumn? in
            guard
                let name = row["column_name"] ?? nil,
                let type = row["column_type"] ?? nil
            else { return nil }
            return WorkspaceDatabaseColumn(
                name: name,
                type: type,
                collation: row["collation_name"] ?? nil,
                isNullable: (row["is_nullable"] ?? nil) == "YES",
                key: (row["column_key"] ?? nil) ?? "",
                defaultValue: row["column_default"] ?? nil,
                extra: (row["extra"] ?? nil) ?? "",
                comment: (row["column_comment"] ?? nil) ?? "",
                generationExpression: (row["generation_expression"] ?? nil) ?? ""
            )
        }

    }
    static func indexes(_ rows: [[String: String?]]) -> [WorkspaceDatabaseIndex] {
        var names: [String] = []
        var columnsByName: [String: [WorkspaceDatabaseIndexColumn]] = [:]
        var propertiesByName: [
            String: (
                isUnique: Bool,
                type: String,
                cardinality: Int64?,
                cardinalityPosition: Int64,
                isVisible: Bool,
                comment: String
            )
        ] = [:]

        for row in rows {
            guard
                let name = row["Key_name"] ?? nil,
                let positionText = row["Seq_in_index"] ?? nil,
                let position = Int64(positionText)
            else { continue }

            let storedColumnName = row["Column_name"] ?? nil
            let expression = row["Expression"] ?? nil
            let columnName = storedColumnName ?? expression ?? ""
            guard !columnName.isEmpty else { continue }

            if propertiesByName[name] == nil {
                names.append(name)
                propertiesByName[name] = (
                    isUnique: (row["Non_unique"] ?? nil).flatMap(Int64.init) == 0,
                    type: (row["Index_type"] ?? nil) ?? "",
                    cardinality: (row["Cardinality"] ?? nil).flatMap(Int64.init),
                    cardinalityPosition: position,
                    isVisible: (row["Visible"] ?? nil) != "NO",
                    comment: (row["Index_comment"] ?? nil) ?? ""
                )
            } else if
                let properties = propertiesByName[name],
                position >= properties.cardinalityPosition
            {
                propertiesByName[name] = (
                    properties.isUnique,
                    properties.type,
                    (row["Cardinality"] ?? nil).flatMap(Int64.init),
                    position,
                    properties.isVisible,
                    properties.comment
                )
            }
            columnsByName[name, default: []].append(
                WorkspaceDatabaseIndexColumn(
                    sequence: position,
                    name: columnName,
                    prefixLength: (row["Sub_part"] ?? nil).flatMap(Int64.init),
                    direction: row["Collation"] ?? nil,
                    isExpression: storedColumnName == nil && expression != nil
                )
            )
        }

        return names.compactMap { name in
            guard let properties = propertiesByName[name] else { return nil }
            return WorkspaceDatabaseIndex(
                name: name,
                columns: columnsByName[name, default: []]
                    .sorted { $0.sequence < $1.sequence },
                isUnique: properties.isUnique,
                type: properties.type,
                cardinality: properties.cardinality,
                isVisible: properties.isVisible,
                comment: properties.comment
            )
        }
    }
    private static func literal(_ text: String) -> String {
        "CONVERT(X'" + text.utf8.map { String(format: "%02X", $0) }.joined() + "' USING utf8mb4)"
    }
}
