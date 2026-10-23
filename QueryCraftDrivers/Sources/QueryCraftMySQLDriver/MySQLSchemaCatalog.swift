import Foundation
#if os(iOS)
import QueryCraftMobileCore
#else
import QueryCraftFeature
#endif

/// Same catalog projections and conversion for desktop and bounded mobile metadata.
enum MySQLSchemaCatalog {
    static let objectsQuery = """
            SELECT
                TABLE_SCHEMA AS database_name,
                TABLE_NAME AS object_name,
                TABLE_TYPE AS object_type,
                TABLE_COMMENT AS object_comment
            FROM information_schema.TABLES
            ORDER BY TABLE_SCHEMA, TABLE_NAME
            """

    static func columnsQuery(_ objects: [WorkspaceSchemaObjectReference]) -> String {
        let objectPredicates = objects.map { reference in
            "(c.TABLE_SCHEMA = \(literal(reference.databaseName)) "
                + "AND c.TABLE_NAME = \(literal(reference.objectName)))"
        }.joined(separator: " OR ")
        return """
            SELECT
                c.TABLE_SCHEMA AS database_name,
                c.TABLE_NAME AS object_name,
                c.COLUMN_NAME AS column_name,
                c.COLUMN_TYPE AS column_type,
                c.ORDINAL_POSITION AS ordinal_position,
                c.COLUMN_COMMENT AS column_comment
            FROM information_schema.COLUMNS AS c
            WHERE \(objectPredicates)
            ORDER BY
                c.TABLE_SCHEMA,
                c.TABLE_NAME,
                c.ORDINAL_POSITION
            """
    }

    static func databases(_ databaseNames: [String], rows: [[String: String?]]) -> [WorkspaceSchemaDatabase] {
        var objectsByDatabase: [String: [WorkspaceSchemaObject]] = [:]
        for row in rows {
            guard
                let databaseName = row["database_name"] ?? nil,
                let objectName = row["object_name"] ?? nil,
                let rawObjectType = row["object_type"] ?? nil
            else { continue }

            let kind: WorkspaceDatabaseObjectKind
            switch rawObjectType {
            case "BASE TABLE": kind = .table
            case "VIEW": kind = .view
            default: continue
            }
            let comment = kind == .view && row["object_comment"] == "VIEW"
                ? ""
                : (row["object_comment"] ?? nil) ?? ""
            objectsByDatabase[databaseName, default: []].append(
                WorkspaceSchemaObject(
                    name: objectName,
                    kind: kind,
                    columns: [],
                    comment: comment
                )
            )
        }

        return databaseNames.map { databaseName in
            WorkspaceSchemaDatabase(
                name: databaseName,
                objects: objectsByDatabase[databaseName, default: []]
            )
        }
    }

    static func columns(_ objects: [WorkspaceSchemaObjectReference], rows: [[String: String?]]) -> [WorkspaceSchemaObjectColumns] {
        var columnsByObject: [WorkspaceSchemaObjectReference: [WorkspaceSchemaColumn]] = [:]
        for row in rows {
            guard
                let databaseName = row["database_name"] ?? nil,
                let objectName = row["object_name"] ?? nil,
                let columnName = row["column_name"] ?? nil,
                let columnType = row["column_type"] ?? nil,
                let ordinalValue = row["ordinal_position"] ?? nil,
                let ordinalPosition = Int(ordinalValue)
            else { continue }
            let key = WorkspaceSchemaObjectReference(
                databaseName: databaseName,
                objectName: objectName
            )
            columnsByObject[key, default: []].append(
                WorkspaceSchemaColumn(
                    name: columnName,
                    type: columnType,
                    ordinalPosition: ordinalPosition,
                    comment: (row["column_comment"] ?? nil) ?? ""
                )
            )
        }

        return objects.map { reference in
            WorkspaceSchemaObjectColumns(
                reference: reference,
                columns: columnsByObject[reference, default: []]
            )
        }
    }

    private static func literal(_ value: String) -> String {
        "CONVERT(0x" + value.utf8.map { String(format: "%02x", $0) }.joined() + " USING utf8mb4)"
    }
}
