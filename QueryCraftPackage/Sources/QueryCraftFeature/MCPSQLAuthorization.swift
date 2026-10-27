import Foundation

struct MCPSQLStatement: Sendable {
    let sql: String
    let kind: SQLStatementKind
    let requiresConfirmation: Bool
    let writesData: Bool
}

enum MCPSQLAuthorization {
    static func statements(_ sql: String, profile: ConnectionProfile, database: String?, policy: MCPPolicy) async throws -> [MCPSQLStatement] {
        guard [.mysql, .postgresql, .doris].contains(profile.databaseType), sql.utf8.count <= 1_048_576 else {
            throw MCPFailure("SQL requires a SQL driver and a script no larger than 1 MB.")
        }
        let mode = policy.effectiveMode(profile, database: database)
        do { _ = try WorkspaceReadOnlyQueryValidator.validate(sql, policy: mode == .readOnly ? .readOnly : .writesAllowed) }
        catch { throw MCPFailure(error.localizedDescription, code: .accessDenied) }
        let parser = try SQLStructuralParser()
        let snapshot = try await parser.parse(.init(revision: .init(1), text: sql))
        // An unparsed tail must never bypass the policy, even when the first statement is safe.
        guard snapshot.unreliableStatementRanges.isEmpty, !snapshot.statements.isEmpty else {
            throw MCPFailure("Cannot reliably parse this SQL script. No statements were executed.")
        }
        let scoped = policy.connectionRule(profile).allowedDatabases
        if let allowed = scoped {
            guard let database, allowed.contains(database) else {
                throw MCPFailure("Select an authorized database first. Use list_databases, then pass database explicitly.", code: .accessDenied)
            }
            if !snapshot.syntaxTree.descendants(named: "keyword_show").isEmpty {
                throw MCPFailure("SHOW is unavailable within a restricted database scope. Use list_databases, list_tables or describe_table for authorized metadata.", code: .accessDenied)
            }
            if !snapshot.syntaxTree.descendants(named: "executable_comment").isEmpty {
                throw MCPFailure("Executable SQL comments cannot be verified within a database scope.", code: .unsupported)
            }
        }
        let tree = try await parser.authorizationTree(revision: .init(1))
        let scope = MCPSQLScope(source: sql as NSString, profile: profile, database: database, policy: policy)
        return try snapshot.statements.map { statement in
            let text = (sql as NSString).substring(with: statement.range.nsRange)
            switch statement.kind {
            case .transaction:
                throw MCPFailure("Use begin_transaction, commit_transaction and rollback_transaction for transaction control.")
            case .control, .unknown:
                throw MCPFailure("This driver cannot safely track session-control or unclassified SQL. Use dedicated tools.", code: .unsupported)
            default: break
            }
            guard let node = tree.children.first(where: { $0.type == "statement" && statement.range.contains($0.range) }) else {
                throw MCPFailure("Cannot resolve this SQL statement's authorization targets.", code: .unsupported)
            }
            let writes = try scope.inspect(node, kind: statement.kind)
            var confirmation = false
            for write in writes {
                let targetMode = policy.effectiveMode(profile, database: write.database)
                switch write.kind {
                case .insert:
                    guard targetMode != .readOnly else { throw MCPFailure("MCP access to the SQL write target is read-only.", code: .accessDenied) }
                case .update, .delete:
                    let bounded = hasBoundedFilter(text)
                    guard targetMode != .readOnly, targetMode == .fullAccess || bounded else {
                        throw MCPFailure("This write requires full access or a verifiable field-to-literal WHERE filter (AND comparisons).", code: .accessDenied)
                    }
                    confirmation = confirmation || !bounded
                case .ddl:
                    guard targetMode == .fullAccess else { throw MCPFailure("DDL requires full access to its target database.", code: .accessDenied) }
                    confirmation = true
                default:
                    throw MCPFailure("SQL write targets cannot be verified for this operation.", code: .unsupported)
                }
            }
            for invocation in node.descendants(named: "invocation") {
                guard let reference = invocation.children.first(where: { $0.type == "object_reference" }) else {
                    throw MCPFailure("Cannot verify SQL function permissions.", code: .accessDenied)
                }
                let name = (sql as NSString).substring(with: reference.range.nsRange).uppercased()
                let parts = scope.identifiers(reference)
                let lastName = parts.last?.uppercased() ?? name
                let builtinName = profile.databaseType == .postgresql && parts.count == 2 && parts.first == "pg_catalog" ? lastName : name
                if scoped != nil, ["LOAD_FILE", "DBLINK", "DBLINK_EXEC", "PG_READ_FILE", "PG_READ_BINARY_FILE", "PG_WRITE_FILE", "PG_LS_DIR"].contains(lastName) {
                    throw MCPFailure("This function can access resources outside the authorized database scope: \(name).", code: .accessDenied)
                }
                let functionMode = policy.effectiveMode(profile, database: try scope.referencedDatabase(reference))
                guard functionMode == .fullAccess || safeFunctions.contains(builtinName)
                    || isSafeContextFunction(invocation, name: builtinName, driver: profile.databaseType) else {
                    throw MCPFailure("SQL function is not verified for read-only or data-write access: \(name).", code: .accessDenied)
                }
            }
            return MCPSQLStatement(sql: text, kind: statement.kind, requiresConfirmation: confirmation, writesData: !writes.isEmpty)
        }
    }

    private static let safeFunctions: Set<String> = ["COUNT", "SUM", "MIN", "MAX", "AVG", "COALESCE", "NULLIF", "IFNULL", "ABS", "ROUND", "FLOOR", "CEIL", "CEILING", "LOWER", "UPPER", "LENGTH", "CHAR_LENGTH", "CONCAT", "SUBSTRING", "SUBSTR", "TRIM", "LTRIM", "RTRIM", "REPLACE", "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP", "DATE", "YEAR", "MONTH", "DAY", "DATE_FORMAT", "TO_CHAR", "CAST", "CONVERT", "ROW_NUMBER", "RANK", "DENSE_RANK", "JSON_EXTRACT", "JSON_UNQUOTE", "MD5", "SHA1", "SHA2", "HEX", "UNHEX", "LEFT", "RIGHT", "CONCAT_WS", "IF", "GREATEST", "LEAST"]

    /// These built-ins only report the current query context or server version. Check the
    /// complete, unqualified name and empty argument list so a routine or overload cannot
    /// inherit the built-in's permission merely by sharing its final name.
    private static func isSafeContextFunction(_ invocation: SQLSyntaxNodeSnapshot, name: String, driver: DatabaseType) -> Bool {
        let names: Set<String>
        switch driver {
        case .mysql, .doris: names = ["DATABASE", "SCHEMA", "VERSION"]
        case .postgresql: names = ["CURRENT_DATABASE", "CURRENT_SCHEMA", "VERSION"]
        default: return false
        }
        return names.contains(name)
            && invocation.children.filter { $0.type != "comment" }.map(\.type) == ["object_reference", "(", ")"]
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
