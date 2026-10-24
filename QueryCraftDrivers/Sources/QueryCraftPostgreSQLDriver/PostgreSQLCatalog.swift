import Foundation
#if canImport(QueryCraftFeature)
import QueryCraftFeature
#else
import QueryCraftMobileCore
#endif

/// Catalog SQL and filtering semantics shared by the desktop and mobile readers.
enum PostgreSQLCatalog {
    static let schemasQuery = """
            SELECT n.nspname::text
            FROM pg_catalog.pg_namespace n
            WHERE n.nspname NOT LIKE 'pg!_%' ESCAPE '!'
              AND n.nspname <> 'information_schema'
              AND has_schema_privilege(current_user, n.oid, 'USAGE')
            ORDER BY n.nspname
            """
    static let objectsQuery = """
            SELECT
                n.nspname::text AS schema_name,
                c.relname::text AS object_name,
                c.relkind::text AS object_kind,
                COALESCE(obj_description(c.oid, 'pg_class'), '')::text AS object_comment
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND n.nspname NOT LIKE 'pg!_%' ESCAPE '!'
              AND n.nspname <> 'information_schema'
              AND has_schema_privilege(current_user, n.oid, 'USAGE')
            ORDER BY n.nspname, c.relname
            """
    static func searchPathQuery(schema: String, local: Bool) -> String {
        "SELECT set_config('search_path', \(literal(identifier(schema))), \(local ? "true" : "false"))"
    }
    static func columnsQuery(schema: String, name: String) -> String {
        """
            SELECT * FROM (
            SELECT
                c.ordinal_position::int AS ordinal_position,
                c.column_name::text AS column_name,
                COALESCE(
                    pg_catalog.format_type(attr.atttypid, attr.atttypmod),
                    c.data_type
                )::text AS column_type,
                c.collation_name::text AS collation_name,
                c.is_nullable::text AS is_nullable,
                CASE WHEN EXISTS (
                    SELECT 1 FROM pg_catalog.pg_index i
                    WHERE i.indrelid = rel.oid AND i.indisprimary
                      AND attr.attnum = ANY(i.indkey)
                ) THEN 'PRI' ELSE '' END::text AS column_key,
                c.column_default::text AS column_default,
                CASE
                    WHEN c.is_identity = 'YES' THEN 'IDENTITY'
                    WHEN c.is_generated = 'ALWAYS' THEN 'STORED GENERATED'
                    ELSE ''
                END::text AS extra,
                COALESCE(pgd.description, '')::text AS column_comment,
                COALESCE(c.generation_expression, '')::text AS generation_expression
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_namespace ns
              ON ns.nspname = c.table_schema
            LEFT JOIN pg_catalog.pg_class rel
              ON rel.relnamespace = ns.oid AND rel.relname = c.table_name
            LEFT JOIN pg_catalog.pg_attribute attr
              ON attr.attrelid = rel.oid AND attr.attname = c.column_name
             AND attr.attnum > 0 AND NOT attr.attisdropped
            LEFT JOIN pg_catalog.pg_description pgd
              ON pgd.objoid = rel.oid AND pgd.objsubid = attr.attnum
            WHERE c.table_schema = \(literal(schema))
              AND c.table_name = \(literal(name))
            UNION ALL
            SELECT
                a.attnum::int,
                a.attname::text,
                pg_catalog.format_type(a.atttypid, a.atttypmod)::text,
                coll.collname::text,
                CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END::text,
                ''::text, NULL::text, ''::text,
                COALESCE(pg_catalog.col_description(rel.oid, a.attnum), '')::text,
                ''::text
            FROM pg_catalog.pg_class rel
            JOIN pg_catalog.pg_namespace ns ON ns.oid = rel.relnamespace
            JOIN pg_catalog.pg_attribute a ON a.attrelid = rel.oid
            LEFT JOIN pg_catalog.pg_collation coll ON coll.oid = a.attcollation
            WHERE rel.relkind = 'm' AND a.attnum > 0 AND NOT a.attisdropped
              AND ns.nspname = \(literal(schema)) AND rel.relname = \(literal(name))
              AND has_column_privilege(rel.oid, a.attnum, 'SELECT')
            ) columns ORDER BY ordinal_position
            """
    }
    static func column(
        _ row: [String: String?]
    ) -> WorkspaceDatabaseColumn? {
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

    static func filterPredicate(
        _ filter: WorkspaceDatabaseDataFilter
    ) throws -> String {
        let conditions = filter.enabledConditions
        guard !conditions.isEmpty else { return "" }
        guard filter.isValid else {
            throw WorkspaceSessionError.invalidDataFilter
        }

        var predicates: [String] = []
        predicates.reserveCapacity(conditions.count)
        for condition in conditions {
            let column = identifier(condition.columnName)
            let predicate: String
            switch condition.operation {
            case .equal:
                predicate = "\(column) = \(literal(condition.value))"
            case .notEqual:
                predicate = "\(column) <> \(literal(condition.value))"
            case .contains:
                predicate = "\(column)::text LIKE "
                    + literal("%\(escapedLike(condition.value))%")
                    + " ESCAPE E'\\\\'"
            case .startsWith:
                predicate = "\(column)::text LIKE "
                    + literal("\(escapedLike(condition.value))%")
                    + " ESCAPE E'\\\\'"
            case .endsWith:
                predicate = "\(column)::text LIKE "
                    + literal("%\(escapedLike(condition.value))")
                    + " ESCAPE E'\\\\'"
            case .lessThan:
                predicate = "\(column) < \(literal(condition.value))"
            case .lessThanOrEqual:
                predicate = "\(column) <= \(literal(condition.value))"
            case .greaterThan:
                predicate = "\(column) > \(literal(condition.value))"
            case .greaterThanOrEqual:
                predicate = "\(column) >= \(literal(condition.value))"
            case .between:
                predicate = "\(column) BETWEEN \(literal(condition.value)) "
                    + "AND \(literal(condition.secondValue))"
            case .isNull:
                predicate = "\(column) IS NULL"
            case .isNotNull:
                predicate = "\(column) IS NOT NULL"
            case .term, .terms, .match, .matchPhrase, .wildcard,
                 .rangeLessThan, .rangeLessThanOrEqual,
                 .rangeGreaterThan, .rangeGreaterThanOrEqual, .exists:
                throw WorkspaceSessionError.invalidDataFilter
            }
            predicates.append("(\(predicate))")
        }
        let separator = filter.logic == .matchAll ? " AND " : " OR "
        return " WHERE " + predicates.joined(separator: separator)
    }

    private static func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    static func literal(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "'", with: "''")
        // Session SQL may change standard_conforming_strings. Explicit escape
        // strings keep catalog and mutation literals correct in either mode.
        if value.contains("\\") { return "E'" + escaped.replacingOccurrences(of: "\\", with: "\\\\") + "'" }
        return "'" + escaped + "'"
    }

    static func identifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

}
