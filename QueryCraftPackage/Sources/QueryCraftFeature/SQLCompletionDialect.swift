import Foundation

struct SQLCompletionDialect: Sendable {
    let keywords: [String]
    let functions: [String]
    let dataTypes: [String]
    let optimizerHints: [String]
    let statementKeywords: [String]
    let insertKeywords: [String]
    let insertBodyKeywords: [String]
    let updateBodyKeywords: [String]
    let assignmentKeywords: [String]
    let deleteKeywords: [String]
    let ddlObjectTypeKeywords: [String]
    let ddlObjectTypeKeywordsWithTemporary: [String]
    let ddlBodyKeywords: [String]
    let selectListKeywords: [String]
    let postRelationKeywords: [String]
    let postJoinRelationKeywords: [String]
    let setOperationKeywords: [String]
    let predicateKeywords: [String]
    let groupingKeywords: [String]
    let orderingKeywords: [String]

    static func forDatabaseType(_ databaseType: DatabaseType) -> Self {
        switch databaseType {
        case .mysql, .doris:
            .mysql
        case .postgresql:
            .postgresql
        case .redis, .elasticsearch:
            preconditionFailure(
                "Non-SQL documents do not use SQL completion."
            )
        }
    }

    static let mysql = Self(
        keywords: SQLStaticCatalog.keywords,
        functions: SQLStaticCatalog.builtInFunctions,
        dataTypes: [
            "BIGINT", "BINARY", "BIT", "BLOB", "BOOL", "BOOLEAN", "CHAR", "DATE",
            "DATETIME", "DECIMAL", "DOUBLE", "ENUM", "FLOAT", "GEOMETRY", "INT",
            "INTEGER", "JSON", "LONGBLOB", "LONGTEXT", "MEDIUMBLOB", "MEDIUMINT",
            "MEDIUMTEXT", "NUMERIC", "REAL", "SET", "SMALLINT", "TEXT", "TIME",
            "TIMESTAMP", "TINYBLOB", "TINYINT", "TINYTEXT", "VARBINARY", "VARCHAR", "YEAR",
        ],
        optimizerHints: SQLStaticCatalog.optimizerHints,
        statementKeywords: SQLStaticCatalog.statementKeywords,
        insertKeywords: SQLStaticCatalog.insertKeywords,
        insertBodyKeywords: SQLStaticCatalog.insertBodyKeywords,
        updateBodyKeywords: SQLStaticCatalog.updateBodyKeywords,
        assignmentKeywords: SQLStaticCatalog.assignmentKeywords,
        deleteKeywords: SQLStaticCatalog.deleteKeywords,
        ddlObjectTypeKeywords: SQLStaticCatalog.ddlObjectTypeKeywords,
        ddlObjectTypeKeywordsWithTemporary:
            SQLStaticCatalog.ddlObjectTypeKeywordsWithTemporary,
        ddlBodyKeywords: SQLStaticCatalog.ddlBodyKeywords,
        selectListKeywords: SQLStaticCatalog.selectListKeywords,
        postRelationKeywords: SQLStaticCatalog.postRelationKeywords,
        postJoinRelationKeywords: SQLStaticCatalog.postJoinRelationKeywords,
        setOperationKeywords: SQLStaticCatalog.setOperationKeywords,
        predicateKeywords: SQLStaticCatalog.predicateKeywords,
        groupingKeywords: SQLStaticCatalog.groupingKeywords,
        orderingKeywords: SQLStaticCatalog.orderingKeywords
    )

    static let postgresql: Self = {
        let functions = [
            "ABS", "AGE", "ARRAY_AGG", "AVG", "CAST", "CEIL", "CEILING",
            "COALESCE", "CONCAT", "COUNT", "CURRENT_DATE", "CURRENT_TIME",
            "CURRENT_TIMESTAMP", "DATE_PART", "DATE_TRUNC", "EXTRACT", "FLOOR",
            "GREATEST", "JSON_AGG", "JSON_BUILD_ARRAY", "JSON_BUILD_OBJECT",
            "JSONB_AGG", "JSONB_BUILD_ARRAY", "JSONB_BUILD_OBJECT", "LEAST",
            "LEFT", "LENGTH", "LOWER", "LTRIM", "MAX", "MIN", "MOD", "NOW",
            "NULLIF", "POSITION", "POWER", "REGEXP_REPLACE", "REPLACE", "RIGHT",
            "ROUND", "RTRIM", "SPLIT_PART", "SQRT", "STRING_AGG", "SUBSTRING",
            "SUM", "TO_CHAR", "TO_DATE", "TO_JSON", "TO_JSONB", "TO_NUMBER",
            "TO_TIMESTAMP", "TRIM", "UPPER",
        ]
        let dataTypes = [
            "ARRAY", "BIGINT", "BIGSERIAL", "BIT", "BOOLEAN", "BOX", "BYTEA",
            "CHAR", "CHARACTER", "CIDR", "CIRCLE", "DATE", "DECIMAL", "DOUBLE PRECISION",
            "INET", "INTEGER", "INTERVAL", "JSON", "JSONB", "LINE", "LSEG",
            "MACADDR", "MACADDR8", "MONEY", "NAME", "NUMERIC", "PATH", "POINT",
            "POLYGON", "REAL", "SERIAL", "SMALLINT", "SMALLSERIAL", "TEXT", "TIME",
            "TIMESTAMP", "TIMESTAMPTZ", "TSQUERY", "TSVECTOR", "UUID", "VARCHAR", "XML",
        ]
        let phrases = [
            "CROSS JOIN", "DEFAULT VALUES", "DO NOTHING", "DO UPDATE", "FETCH FIRST",
            "FOREIGN KEY", "FOR SHARE", "FOR UPDATE", "FULL JOIN", "GROUP BY",
            "IF EXISTS", "IF NOT EXISTS", "INNER JOIN", "IS DISTINCT FROM", "IS NOT NULL",
            "IS NULL", "LEFT JOIN", "NATURAL JOIN", "NOT NULL", "NULLS FIRST",
            "NULLS LAST", "ON CONFLICT", "ORDER BY", "PARTITION BY", "PRIMARY KEY",
            "RELEASE SAVEPOINT", "RIGHT JOIN", "START TRANSACTION", "UNION ALL",
            "WITH RECURSIVE",
        ]
        let baseKeywords = [
            "ABORT", "ADD", "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC",
            "BEGIN", "BETWEEN", "BY", "CALL", "CASCADE", "CASE", "CHECK", "COLLATE",
            "COLUMN", "COMMENT", "COMMIT", "CONCURRENTLY", "CONFLICT", "CONSTRAINT",
            "COPY", "CREATE", "CROSS", "CURRENT", "DATABASE", "DEALLOCATE", "DEFAULT",
            "DELETE", "DESC", "DISTINCT", "DO", "DROP", "ELSE", "END", "EXCEPT",
            "EXECUTE", "EXISTS", "EXPLAIN", "FALSE", "FETCH", "FIRST", "FOR", "FOREIGN",
            "FROM", "FULL", "FUNCTION", "GRANT", "GROUP", "HAVING", "ILIKE", "IN",
            "INDEX", "INHERITS", "INNER", "INSERT", "INTERSECT", "INTO", "IS", "JOIN",
            "KEY", "LATERAL", "LEFT", "LIKE", "LIMIT", "MATERIALIZED", "MERGE", "NATURAL",
            "NOT", "NOTIFY", "NULL", "OFFSET", "ON", "ONLY", "OR", "ORDER", "OUTER",
            "OVER", "PARTITION", "PREPARE", "PRIMARY", "PROCEDURE", "RECURSIVE", "REFERENCES",
            "REINDEX", "RELEASE", "RENAME", "RESET", "RESTRICT", "RETURNING", "REVOKE",
            "RIGHT", "ROLLBACK", "ROWS", "SAVEPOINT", "SCHEMA", "SELECT", "SEQUENCE",
            "SET", "SHOW", "TABLE", "TABLESPACE", "TEMP", "TEMPORARY", "THEN", "TO",
            "TRANSACTION", "TRIGGER", "TRUE", "TRUNCATE", "UNION", "UNIQUE", "UNLISTEN",
            "UPDATE", "USING", "VACUUM", "VALUES", "VERBOSE", "VIEW", "WHEN", "WHERE",
            "WINDOW", "WITH", "WITHOUT",
        ]
        let keywords = orderedUnique(baseKeywords + phrases + dataTypes)
        let postRelation = [
            "JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "INNER JOIN", "CROSS JOIN",
            "NATURAL JOIN", "WHERE", "GROUP BY", "HAVING", "WINDOW", "ORDER BY", "LIMIT",
            "OFFSET", "FETCH FIRST", "UNION", "UNION ALL", "INTERSECT", "EXCEPT",
            "FOR UPDATE", "FOR SHARE",
        ]
        let objectTypes = [
            "TABLE", "VIEW", "MATERIALIZED VIEW", "DATABASE", "SCHEMA", "INDEX", "FUNCTION",
            "PROCEDURE", "TRIGGER", "ROLE", "USER", "SEQUENCE", "TYPE", "TABLESPACE",
        ]
        return Self(
            keywords: keywords,
            functions: functions,
            dataTypes: dataTypes,
            optimizerHints: [],
            statementKeywords: [
                "WITH", "WITH RECURSIVE", "SELECT", "VALUES", "INSERT", "UPDATE", "DELETE",
                "MERGE", "CREATE", "ALTER", "DROP", "TRUNCATE", "COMMENT", "COPY", "EXPLAIN",
                "ANALYZE", "VACUUM", "REINDEX", "GRANT", "REVOKE", "SET", "SHOW", "RESET",
                "BEGIN", "START TRANSACTION", "COMMIT", "ROLLBACK", "SAVEPOINT",
                "RELEASE SAVEPOINT", "PREPARE", "EXECUTE", "DEALLOCATE", "NOTIFY", "LISTEN",
            ],
            insertKeywords: ["INTO"],
            insertBodyKeywords: [
                "VALUES", "SELECT", "DEFAULT VALUES", "ON CONFLICT", "RETURNING",
            ],
            updateBodyKeywords: ["SET"],
            assignmentKeywords: ["FROM", "WHERE", "RETURNING"],
            deleteKeywords: ["FROM"],
            ddlObjectTypeKeywords: objectTypes,
            ddlObjectTypeKeywordsWithTemporary: ["TEMP", "TEMPORARY"] + objectTypes,
            ddlBodyKeywords: [
                "ADD", "COLUMN", "DROP", "ALTER COLUMN", "RENAME TO", "IF EXISTS",
                "IF NOT EXISTS", "CASCADE", "RESTRICT",
            ],
            selectListKeywords: [
                "INTO", "FROM", "AS", "ALL", "DISTINCT", "CASE", "EXISTS", "LATERAL",
            ],
            postRelationKeywords: postRelation,
            postJoinRelationKeywords: ["ON", "USING"] + postRelation,
            setOperationKeywords: ["UNION", "UNION ALL", "INTERSECT", "EXCEPT"],
            predicateKeywords: [
                "AND", "OR", "NOT", "IN", "EXISTS", "ANY", "ALL", "IS NULL",
                "IS NOT NULL", "IS DISTINCT FROM", "LIKE", "ILIKE", "BETWEEN", "CASE",
                "WHEN", "THEN", "ELSE", "END",
            ],
            groupingKeywords: ["HAVING", "WINDOW", "ORDER BY", "LIMIT", "OFFSET", "FETCH FIRST"],
            orderingKeywords: [
                "ASC", "DESC", "NULLS FIRST", "NULLS LAST", "LIMIT", "OFFSET", "FETCH FIRST",
            ]
        )
    }()

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
