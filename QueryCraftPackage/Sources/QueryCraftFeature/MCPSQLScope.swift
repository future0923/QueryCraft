import Foundation

/// Resolve the actual objects in a statement, including write targets which are not
/// represented by the editor's FROM/JOIN relation list (INSERT, DELETE and DDL).
struct MCPSQLScope {
    struct Write {
        let database: String?
        let kind: SQLStatementKind
    }
    let source: NSString
    let profile: ConnectionProfile
    let database: String?
    let policy: MCPPolicy

    func identifiers(_ node: SQLSyntaxNodeSnapshot) -> [String] {
        node.descendants(named: "identifier").map {
            let text = source.substring(with: $0.range.nsRange)
            if let quote = text.first, ["`", "\""].contains(quote), text.last == quote {
                return String(text.dropFirst().dropLast()).replacingOccurrences(of: String(repeating: String(quote), count: 2), with: String(quote))
            }
            return profile.databaseType == .postgresql ? text.lowercased() : text
        }
    }

    func referencedDatabase(_ node: SQLSyntaxNodeSnapshot, column: Bool = false) throws -> String? {
        let names = identifiers(node)
        let parts = column ? Array(names.dropLast()) : names
        if profile.databaseType == .postgresql {
            if parts.count >= 3, let catalog = parts.first, catalog != database {
                throw MCPFailure("SQL references another PostgreSQL database: \(catalog).", code: .accessDenied)
            }
            return database // A two-part PostgreSQL name is schema.object, not database.object.
        }
        guard parts.count <= 2 else {
            throw MCPFailure("SQL catalog-qualified objects cannot be verified by this driver.", code: .unsupported)
        }
        return parts.count == 2 ? parts.first : database
    }

    func checkScope(_ name: String?) throws {
        if let allowed = policy.connectionRule(profile).allowedDatabases {
            guard let name, allowed.contains(name) else {
                throw MCPFailure("SQL references a database outside the authorized scope.", code: .accessDenied)
            }
        }
    }

    func inspect(_ node: SQLSyntaxNodeSnapshot, kind: SQLStatementKind) throws -> [Write] {
        var writes: [Write] = []
        func write(_ reference: SQLSyntaxNodeSnapshot, _ operation: SQLStatementKind, column: Bool = false) throws {
            let target = try referencedDatabase(reference, column: column)
            try checkScope(target)
            writes.append(.init(database: target, kind: operation))
        }
        func visit(_ current: SQLSyntaxNodeSnapshot, parent: String? = nil) throws {
            if current.type == "field" { return } // table aliases/column qualifiers are not database targets.
            if current.type == "object_reference" {
                // Nested object references are one qualified name, not separate accesses.
                let target = try referencedDatabase(current, column: parent == "comment_statement" && current.children.contains { $0.type == "object_reference" })
                try checkScope(target)
                return
            }
            let direct = current.children.filter { $0.type == "object_reference" }
            switch current.type {
            case "insert":
                if let target = direct.first { try write(target, .insert) }
            case "update":
                let relations = current.children.flatMap { child -> [SQLSyntaxNodeSnapshot] in
                    if child.type == "relation" { return [child] }
                    if child.type == "join" { return child.children.filter { $0.type == "relation" } }
                    return []
                }
                let assignments = current.children.filter { $0.type == "assignment" }
                var targets: [SQLSyntaxNodeSnapshot] = []
                for assignment in assignments {
                    guard let field = assignment.children.first(where: { $0.type == "field" }) else { continue }
                    let qualifier = field.children.first(where: { $0.type == "object_reference" }).map(identifiers)?.last
                    if let qualifier {
                        targets += relations.filter { relation in
                            let alias = relation.children.last(where: { $0.type == "identifier" }).flatMap { identifiers($0).first }
                            return alias == qualifier || relation.children.first(where: { $0.type == "object_reference" }).map(identifiers)?.last == qualifier
                        }
                    } else { targets += relations }
                }
                guard !targets.isEmpty else { throw MCPFailure("Cannot resolve SQL UPDATE targets.", code: .unsupported) }
                for relation in targets {
                    if let target = relation.children.first(where: { $0.type == "object_reference" }) { try write(target, .update(hasWhereClause: !current.descendants(named: "where").isEmpty)) }
                }
            case "statement" where current.children.contains(where: { $0.type == "delete" }):
                if let from = current.children.first(where: { $0.type == "from" }),
                   let target = from.children.first(where: { $0.type == "object_reference" }) { try write(target, .delete(hasWhereClause: !from.descendants(named: "where").isEmpty)) }
            case "create_table", "alter_table", "drop_table", "create_view", "alter_view", "drop_view", "create_materialized_view", "alter_materialized_view", "drop_materialized_view", "create_index", "alter_index", "comment_statement", "create_type", "alter_type", "drop_type", "create_sequence", "alter_sequence", "drop_sequence", "create_function", "create_procedure", "create_trigger", "drop_function", "drop_procedure":
                for target in direct { try write(target, .ddl(.other), column: current.type == "comment_statement" && target.children.contains { $0.type == "object_reference" }) }
            case "drop_index":
                // In MySQL the ON table is the target; in PostgreSQL the index name is schema-qualified.
                let targets = current.children.contains(where: { $0.type == "keyword_on" }) ? Array(direct.suffix(1)) : direct
                for target in targets { try write(target, .ddl(.drop)) }
            case "rename_object":
                for target in direct { try write(target, kind) }
            case "create_database", "drop_database":
                guard let name = identifiers(current).first else { throw MCPFailure("Cannot resolve database DDL target.", code: .unsupported) }
                try checkScope(name)
                writes.append(.init(database: name, kind: kind))
            case "create_schema", "drop_schema", "alter_schema":
                let target = profile.databaseType == .postgresql ? database : identifiers(current).first
                try checkScope(target)
                writes.append(.init(database: target, kind: kind))
            case "statement" where current.children.contains(where: { ["keyword_truncate", "keyword_rename"].contains($0.type) }):
                for target in direct { try write(target, kind) }
            default: break
            }
            for child in current.children { try visit(child, parent: current.type) }
        }
        try visit(node)
        if kind.requiresWriteAccess, writes.isEmpty {
            // Administrative/procedural statements have no verifiable database target.
            guard policy.permitsAllObjectWrites(profile) else {
                throw MCPFailure("This SQL operation has no verifiable database-local target.", code: .unsupported)
            }
            writes.append(.init(database: database, kind: kind))
        }
        return writes
    }
}
