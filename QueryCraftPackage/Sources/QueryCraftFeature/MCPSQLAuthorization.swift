import Foundation

struct MCPSQLStatement: Sendable {
    let sql: String
    let kind: SQLStatementKind
}

enum MCPSQLAuthorization {
    static func statements(_ sql: String, profile: ConnectionProfile, database: String?, policy: MCPPolicy) async throws -> [MCPSQLStatement] {
        guard [.mysql, .postgresql, .doris].contains(profile.databaseType), sql.utf8.count <= 1_048_576 else {
            throw MCPFailure("SQL requires a SQL driver and a script no larger than 1 MB.")
        }
        let mode = policy.effectiveMode(profile, database: database)
        _ = try WorkspaceReadOnlyQueryValidator.validate(sql, policy: mode == .readOnly ? .readOnly : .writesAllowed)
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(.init(revision: .init(1), text: sql))
        // An unparsed tail must never bypass the policy, even when the first statement is safe.
        guard snapshot.unreliableStatementRanges.isEmpty, !snapshot.statements.isEmpty else {
            throw MCPFailure("Cannot reliably parse this SQL script. No statements were executed.")
        }
        let scoped = policy.connectionRule(profile).allowedDatabases
        if let allowed = scoped {
            if !snapshot.syntaxTree.descendants(named: "keyword_show").isEmpty
                || !snapshot.syntaxTree.descendants(named: "show").isEmpty {
                throw MCPFailure("Use metadata tools within a restricted database scope.")
            }
            guard let database, allowed.contains(database) else { throw MCPFailure("Select an authorized database first.", code: .accessDenied) }
            if profile.databaseType != .postgresql {
                for reference in snapshot.relationReferences {
                    if let referencedDatabase = reference.databaseName, !allowed.contains(referencedDatabase) {
                        throw MCPFailure("SQL references a database outside the authorized scope.", code: .accessDenied)
                    }
                }
            }
            // Dynamic SQL, session switches and routine invocations can escape a static database scope.
            let upper = sql.uppercased()
            guard !upper.contains("/*!"), !upper.contains("/*M!"),
                  !upper.contains("LOAD_FILE"), !upper.contains("DBLINK"), !upper.contains("PG_READ_FILE") else {
                throw MCPFailure("SQL cannot be verified within this database scope.", code: .accessDenied)
            }
        }
        if mode != .fullAccess || scoped != nil {
            let safeFunctions: Set<String> = ["COUNT", "SUM", "MIN", "MAX", "AVG", "COALESCE", "NULLIF", "IFNULL", "ABS", "ROUND", "FLOOR", "CEIL", "CEILING", "LOWER", "UPPER", "LENGTH", "CHAR_LENGTH", "CONCAT", "SUBSTRING", "SUBSTR", "TRIM", "LTRIM", "RTRIM", "REPLACE", "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP", "DATE", "YEAR", "MONTH", "DAY", "DATE_FORMAT", "TO_CHAR", "CAST", "CONVERT", "ROW_NUMBER", "RANK", "DENSE_RANK", "JSON_EXTRACT", "JSON_UNQUOTE"]
            for invocation in snapshot.syntaxTree.descendants(named: "invocation") {
                guard let reference = invocation.descendants(named: "object_reference").first else {
                    throw MCPFailure("Cannot verify SQL function permissions.", code: .accessDenied)
                }
                let name = (sql as NSString).substring(with: reference.range.nsRange).uppercased()
                guard safeFunctions.contains(name) else {
                    throw MCPFailure("This SQL function requires unrestricted full access: \(name)")
                }
            }
        }
        return try snapshot.statements.map { statement in
            let text = (sql as NSString).substring(with: statement.range.nsRange)
            switch statement.kind {
            case .transaction:
                throw MCPFailure("Use begin_transaction, commit_transaction and rollback_transaction for transaction control.")
            case .read: break
            case .insert:
                guard mode != .readOnly else { throw MCPFailure("MCP access is read-only.", code: .accessDenied) }
            case .update(let hasWhere), .delete(let hasWhere):
                guard mode != .readOnly, mode == .fullAccess || (hasWhere && hasBoundedFilter(text)) else {
                    throw MCPFailure("This write requires full access or a verifiable field-to-literal WHERE filter (AND comparisons).", code: .accessDenied)
                }
            case .ddl:
                guard mode == .fullAccess, scoped == nil else { throw MCPFailure("DDL requires full access without a restricted database scope.", code: .accessDenied) }
            case .control, .unknown:
                throw MCPFailure("This driver cannot safely track session-control or unclassified SQL. Use the dedicated transaction tools.", code: .unsupported)
            }
            return MCPSQLStatement(sql: text, kind: statement.kind)
        }
    }
    /// Deliberately conservative: a WHERE keyword alone does not make a write bounded.
    /// Complex predicates remain available under explicit full access.
    static func hasBoundedFilter(_ sql: String) -> Bool {
        let identifier = #"(?:[A-Za-z_][A-Za-z0-9_]*|`[^`]+`|"[^"]+")(?:\.(?:[A-Za-z_][A-Za-z0-9_]*|`[^`]+`|"[^"]+"))?"#
        let literal = #"(?:-?[0-9]+(?:\.[0-9]+)?|'(?:[^'\\]|'')*')"#
        let comparison = identifier + #"\s*(?:=|<>|!=|<=|>=|<|>)\s*"# + literal
        let pattern = #"(?is)\bWHERE\s+"# + comparison + #"(?:\s+AND\s+"# + comparison + #")*\s*;?\s*$"#
        return sql.range(of: pattern, options: .regularExpression) != nil
    }

}
