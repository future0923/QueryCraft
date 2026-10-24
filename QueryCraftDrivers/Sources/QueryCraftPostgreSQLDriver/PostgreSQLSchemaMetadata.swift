import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

/// The same catalog query and conversion are used by the installed driver and mobile forms.
enum PostgreSQLSchemaMetadata {
    static func indexesQuery(schema: String, name: String) -> String {
        """
            SELECT
                idx.relname::text AS index_name,
                (ord.ordinality + 1)::text AS column_sequence,
                CASE
                    WHEN i.indkey[ord.ordinality] = 0
                        THEN pg_get_indexdef(
                            i.indexrelid,
                            (ord.ordinality + 1)::int,
                            true
                        )
                    ELSE attr.attname
                END::text AS column_name,
                i.indisunique::text AS is_unique,
                i.indisprimary::text AS is_primary,
                am.amname::text AS index_type,
                COALESCE(obj_description(idx.oid, 'pg_class'), '')::text AS index_comment,
                (i.indkey[ord.ordinality] = 0)::text AS is_expression,
                ((i.indoption[ord.ordinality] & 1) = 1)::text AS is_descending
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class tbl ON tbl.oid = i.indrelid
            JOIN pg_catalog.pg_namespace ns ON ns.oid = tbl.relnamespace
            JOIN pg_catalog.pg_class idx ON idx.oid = i.indexrelid
            JOIN pg_catalog.pg_am am ON am.oid = idx.relam
            CROSS JOIN LATERAL generate_subscripts(i.indkey, 1) ord(ordinality)
            LEFT JOIN pg_catalog.pg_attribute attr
              ON attr.attrelid = tbl.oid
             AND attr.attnum = i.indkey[ord.ordinality]
            WHERE ns.nspname = \(PostgreSQLCatalog.literal(schema))
              AND tbl.relname = \(PostgreSQLCatalog.literal(name))
            ORDER BY i.indisprimary DESC, idx.relname, ord.ordinality
            """
    }
    static func indexes(_ rows: [[String: String?]]) -> [WorkspaceDatabaseIndex] {
        var order: [String] = []
        var columnsByIndex: [String: [WorkspaceDatabaseIndexColumn]] = [:]
        var properties: [String: (isUnique: Bool, isPrimary: Bool, type: String, comment: String)] = [:]
        for row in rows {
            guard
                let name = row["index_name"] ?? nil,
                let sequenceText = row["column_sequence"] ?? nil,
                let sequence = Int64(sequenceText),
                let column = row["column_name"] ?? nil,
                let uniqueText = row["is_unique"] ?? nil,
                let primaryText = row["is_primary"] ?? nil,
                let type = row["index_type"] ?? nil,
                let expressionText = row["is_expression"] ?? nil,
                let descendingText = row["is_descending"] ?? nil
            else { continue }
            if properties[name] == nil { order.append(name) }
            properties[name] = (
                pgBool(uniqueText),
                pgBool(primaryText),
                type,
                (row["index_comment"] ?? nil) ?? ""
            )
            columnsByIndex[name, default: []].append(
                WorkspaceDatabaseIndexColumn(
                    sequence: sequence,
                    name: column,
                    prefixLength: nil,
                    direction: pgBool(descendingText) ? "D" : "A",
                    isExpression: pgBool(expressionText)
                )
            )
        }
        return order.compactMap { name in
            guard let value = properties[name] else { return nil }
            return WorkspaceDatabaseIndex(
                name: name,
                columns: columnsByIndex[name, default: []],
                isUnique: value.isUnique,
                isPrimary: value.isPrimary,
                type: value.type.lowercased(),
                cardinality: nil,
                isVisible: true,
                comment: value.comment
            )
        }
    }
    private static func pgBool(_ value: String) -> Bool { value == "t" || value == "true" || value == "1" }
    static func ddl(schema: String, name: String, columns: [WorkspaceDatabaseColumn]) -> String {
        let definitions = columns.map { column in
            var definition = "    \(PostgreSQLCatalog.identifier(column.name)) \(column.type)"
            if let defaultValue = column.defaultValue { definition += " DEFAULT \(defaultValue)" }
            if !column.isNullable { definition += " NOT NULL" }
            return definition
        }
        return "CREATE TABLE \(PostgreSQLCatalog.identifier(schema)).\(PostgreSQLCatalog.identifier(name)) (\n"
            + definitions.joined(separator: ",\n") + "\n);"
    }
}
