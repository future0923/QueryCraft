import Foundation

/// MySQL catalog adapter for the native Swift comparison engine. Catalog query errors
/// abort the snapshot; permissions failures must never turn into DROP proposals.
struct SchemaComparisonCatalogLoader: SchemaComparisonSnapshotLoading {
    let sessionFactory: any WorkspaceSessionFactory
    var options = SchemaComparisonOptions()

    func load(configuration: DatabaseConnectionConfiguration,
              progress: @escaping @Sendable (SchemaComparisonLoadProgress) async -> Void) async throws -> SchemaComparisonSnapshot {
        guard configuration.databaseProduct == .mysql, let requestedDatabase = configuration.database, !requestedDatabase.isEmpty else { throw SchemaComparisonError.invalidDatabase }
        if let message = options.validationMessage { throw SchemaEngineFailure(message) }
        try Task.checkCancellation()
        let session = await sessionFactory.makeSession(configuration: configuration)
        do {
            let connecting = Task { try await session.connect() }
            try await connecting.value
            try Task.checkCancellation()
            let server = try await query("SELECT @@version AS version, @@version_comment AS comment, @@server_uuid AS server_id, @@lower_case_table_names AS case_mode, @@sql_mode AS sql_mode, DATABASE() AS current_database", session: session, database: requestedDatabase).first ?? .null
            guard !server["server_id"].string.isEmpty, MySQLSchemaCompatibility.supportsMetadata(version: server["version"].string, comment: server["comment"].string) else { throw SchemaComparisonError.unsupportedServer }
            let database = server["current_database"].string
            guard !database.isEmpty else { throw SchemaComparisonError.invalidDatabase }
            let caseMode = Int(server["case_mode"].string) ?? 0
            try await validateCatalogVisibility(session: session, database: database, version: server["version"].string)
            let db = Self.literal(database)
            let allObjects = try await query("SELECT TABLE_NAME AS name, TABLE_TYPE AS table_type, TABLE_COMMENT AS comment FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(db) ORDER BY TABLE_NAME", session: session, database: database)
            let objects = allObjects.filter {
                ($0["table_type"].string.contains("VIEW") ? options.views : options.tables)
                    && options.includes($0["name"].string, caseInsensitive: caseMode != 0)
            }
            let routines = options.functions ? try await query("SELECT ROUTINE_NAME AS name, ROUTINE_TYPE AS kind, DTD_IDENTIFIER AS data_type, ROUTINE_DEFINITION AS definition FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = \(db) ORDER BY ROUTINE_TYPE, ROUTINE_NAME", session: session, database: database) : []
            let total = objects.count + routines.count
            await progress(.init(total: total))
            let columns = options.tables ? try await query("SELECT TABLE_NAME AS table_name, COLUMN_NAME AS name, COLUMN_TYPE AS data_type, IS_NULLABLE AS nullable, COLUMN_DEFAULT AS default_value, COLUMN_KEY AS key_kind, EXTRA AS extra, COLUMN_COMMENT AS comment, GENERATION_EXPRESSION AS generation_expression, NUMERIC_PRECISION AS numeric_precision, NUMERIC_SCALE AS numeric_scale, CHARACTER_MAXIMUM_LENGTH AS character_maximum_length, CHARACTER_SET_NAME AS character_set, COLLATION_NAME AS collation FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = \(db) ORDER BY TABLE_NAME, ORDINAL_POSITION", session: session, database: database) : []
            let indexRows: [SchemaEngineJSON]
            if options.tables {
                let expression = Self.hasExpressionMetadata(server["version"].string) ? "EXPRESSION" : "NULL"
                indexRows = try await query("SELECT TABLE_NAME AS table_name, INDEX_NAME AS name, COLUMN_NAME AS column_name, \(expression) AS expression, NON_UNIQUE AS non_unique, INDEX_TYPE AS index_type, INDEX_COMMENT AS comment FROM information_schema.STATISTICS WHERE TABLE_SCHEMA = \(db) ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX", session: session, database: database)
            } else { indexRows = [] }
            let foreignKeys = options.tables ? try await query("""
                SELECT k.TABLE_NAME AS table_name, k.CONSTRAINT_NAME AS name, k.COLUMN_NAME AS column_name,
                       k.REFERENCED_TABLE_SCHEMA AS ref_schema, k.REFERENCED_TABLE_NAME AS ref_table,
                       k.REFERENCED_COLUMN_NAME AS ref_column, r.UPDATE_RULE AS on_update, r.DELETE_RULE AS on_delete
                FROM information_schema.KEY_COLUMN_USAGE k JOIN information_schema.REFERENTIAL_CONSTRAINTS r
                ON r.CONSTRAINT_SCHEMA=k.CONSTRAINT_SCHEMA AND r.TABLE_NAME=k.TABLE_NAME AND r.CONSTRAINT_NAME=k.CONSTRAINT_NAME
                WHERE k.TABLE_SCHEMA=\(db) AND k.REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY k.TABLE_NAME,k.CONSTRAINT_NAME,k.ORDINAL_POSITION
                """, session: session, database: database) : []
            let triggers = options.tables && options.triggers ? try await query("SELECT EVENT_OBJECT_TABLE AS table_name, TRIGGER_NAME AS name, EVENT_MANIPULATION AS event, ACTION_TIMING AS timing, ACTION_STATEMENT AS statement, ACTION_ORDER AS action_order FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA=\(db) ORDER BY EVENT_OBJECT_TABLE,ACTION_TIMING,EVENT_MANIPULATION,ACTION_ORDER,TRIGGER_NAME", session: session, database: database) : []
            let parameters = !routines.isEmpty ? try await query("SELECT SPECIFIC_NAME AS name, ROUTINE_TYPE AS routine_type, PARAMETER_MODE AS mode, PARAMETER_NAME AS parameter_name, DTD_IDENTIFIER AS data_type, ORDINAL_POSITION AS position FROM information_schema.PARAMETERS WHERE SPECIFIC_SCHEMA=\(db) AND ORDINAL_POSITION > 0 ORDER BY SPECIFIC_NAME,ORDINAL_POSITION", session: session, database: database) : []
            let columnGroups = Dictionary(grouping: columns, by: { $0["table_name"].string })
            let indexGroups = Dictionary(grouping: indexRows, by: { $0["table_name"].string })
            let fkGroups = Dictionary(grouping: foreignKeys, by: { $0["table_name"].string })
            let triggerGroups = Dictionary(grouping: triggers, by: { $0["table_name"].string })
            var details: [SchemaEngineJSON] = [], snapshots: [SchemaComparisonSnapshot.Object] = []
            for (i, object) in objects.enumerated() {
                try Task.checkCancellation()
                let name = object["name"].string
                let isView = object["table_type"].string.contains("VIEW")
                let rows = try await query("SHOW CREATE \(isView ? "VIEW" : "TABLE") \(Self.identifier(database)).\(Self.identifier(name))", session: session, database: database)
                let ddl = rows.first?[isView ? "Create View" : "Create Table"].string ?? ""
                guard !ddl.isEmpty else { throw SchemaEngineFailure("\(name): " + AppCopy.current.text("未能读取完整 DDL。", "Complete DDL was not returned.")) }
                let convertedColumns = isView ? [] : (columnGroups[name] ?? []).map(Self.column)
                let convertedIndexes = isView ? [] : Self.indexes(indexGroups[name] ?? [])
                // Fetch index metadata together; the comparison applies the
                // primary/unique/ordinary-index options independently.
                let convertedFKs = (fkGroups[name] ?? []).map { row in
                    SchemaEngineJSON.object(["name": row["name"], "column": row["column_name"], "ref_schema": row["ref_schema"], "ref_table": row["ref_table"], "ref_column": row["ref_column"], "on_update": row["on_update"], "on_delete": row["on_delete"]])
                }
                let convertedTriggers = (triggerGroups[name] ?? []).map { row in
                    SchemaEngineJSON.object(["name": row["name"], "event": row["event"], "timing": row["timing"], "statement": row["statement"], "action_order": row["action_order"]])
                }
                details.append(.object(["name": .string(name), "ddl": .string(ddl), "columns": .array(convertedColumns), "indexes": .array(convertedIndexes), "foreignKeys": .array(convertedFKs), "triggers": .array(convertedTriggers)]))
                snapshots.append(.init(name: name, ddl: ddl, definition: nil, error: nil))
                await progress(.init(completed: i + 1, total: total, objectName: name))
            }
            var functions: [SchemaEngineJSON] = []
            for (i, routine) in routines.enumerated() {
                try Task.checkCancellation()
                let name = routine["name"].string, kind = routine["kind"].string
                guard ["FUNCTION", "PROCEDURE"].contains(kind) else { continue }
                let rows = try await query("SHOW CREATE \(kind) \(Self.identifier(database)).\(Self.identifier(name))", session: session, database: database)
                let ddl = rows.first?[kind == "FUNCTION" ? "Create Function" : "Create Procedure"].string ?? ""
                guard !ddl.isEmpty else { throw SchemaEngineFailure("\(name): " + AppCopy.current.text("缺少读取存储程序定义的权限。", "Permission to read the routine definition is missing.")) }
                let arguments = parameters.filter { $0["name"].string == name && $0["routine_type"].string == kind }.map {
                    [$0["mode"].string, Self.identifier($0["parameter_name"].string), $0["data_type"].string].filter { !$0.isEmpty }.joined(separator: " ")
                }.joined(separator: ", ")
                functions.append(.object(["name": .string(name), "functionType": .string(kind), "dataType": routine["data_type"], "definition": .string(ddl), "arguments": .string(arguments)]))
                await progress(.init(completed: objects.count + i + 1, total: total, objectName: name))
            }
            try Task.checkCancellation()
            await session.close()
            return .init(database: database, serverID: server["server_id"].string, version: server["version"].string,
                         sqlMode: server["sql_mode"].string, lowerCaseTableNames: caseMode, objects: snapshots, capturedAt: Date(),
                         engineMetadata: .object(["tables": .array(objects), "details": .array(details), "functions": .array(functions), "sequences": .array([]), "rules": .array([]), "owners": .array([])]))
        } catch { await session.close(); throw error }
    }

    private func validateCatalogVisibility(session: any WorkspaceSession, database: String, version: String) async throws {
        var grants = try await query("SHOW GRANTS FOR CURRENT_USER", session: session, database: database)
        if Int(version.split(separator: ".").first ?? "0") ?? 0 >= 8 {
            let roles = try await query("SELECT CURRENT_ROLE() AS roles", session: session, database: database).first?["roles"].string ?? "NONE"
            if roles != "NONE", let tokens = try? SchemaComparisonDDL.tokens(roles), !tokens.isEmpty {
                var accounts: [String] = [], valid = true, i = 0
                while i < tokens.count {
                    guard i + 2 < tokens.count, tokens[i].text.first == "`", tokens[i+1].text == "@", tokens[i+2].text.first == "`" else { valid = false; break }
                    accounts.append(Self.identifier(tokens[i].identifier) + "@" + Self.identifier(tokens[i+2].identifier)); i += 3
                    if i < tokens.count { guard tokens[i].text == "," else { valid = false; break }; i += 1 }
                }
                if valid, !accounts.isEmpty {
                    grants += try await query("SHOW GRANTS FOR CURRENT_USER USING " + accounts.joined(separator: ","), session: session, database: database)
                }
            }
        }
        var tablesVisible = false, routinesVisible = false, triggersVisible = false
        for row in grants {
            for value in row.dictionary.values {
                guard let tokens = try? SchemaComparisonDDL.tokens(value.string), tokens.first?.keyword == "GRANT",
                      let on = tokens.firstIndex(where: { $0.keyword == "ON" }), on + 3 < tokens.count,
                      tokens[on+2].text == ".", tokens[on+3].text == "*" else { continue }
                let scope = tokens[on+1].identifier
                let global = scope == "*"
                guard global || Self.grantPattern(scope, matches: database) else { continue }
                let privileges = Set(tokens[..<on].map(\.keyword))
                let all = privileges.contains("ALL")
                tablesVisible = tablesVisible || all || privileges.contains("SELECT")
                routinesVisible = routinesVisible || all || global && (privileges.contains("SELECT") || privileges.contains("SHOW_ROUTINE")) || privileges.contains("EXECUTE") || privileges.contains("ROUTINE")
                triggersVisible = triggersVisible || all || privileges.contains("TRIGGER")
            }
        }
        if (options.tables || options.views) && !tablesVisible {
            throw SchemaEngineFailure(AppCopy.current.text("需要数据库范围的 SELECT 权限，才能确认对象清单完整；当前表级权限不足以判断对象是否缺失。", "Database-wide SELECT is required to confirm a complete catalog; table-level permissions cannot prove that an object is absent."))
        }
        if options.functions && !routinesVisible {
            throw SchemaEngineFailure(AppCopy.current.text("无法确认存储程序清单完整。请授予读取存储程序的权限，或在比较选项中关闭函数与存储过程。", "Routine catalog visibility is incomplete. Grant routine metadata access or turn off functions and procedures in comparison options."))
        }
        if options.tables && options.triggers && !triggersVisible {
            throw SchemaEngineFailure(AppCopy.current.text("无法确认触发器清单完整。请授予数据库范围的 TRIGGER 权限，或在比较选项中关闭触发器。", "Trigger catalog visibility is incomplete. Grant database-wide TRIGGER or turn off triggers in comparison options."))
        }
    }
    private static func grantPattern(_ pattern: String, matches database: String) -> Bool {
        var escaped = false, expression = "^"
        for character in pattern {
            if escaped { expression += NSRegularExpression.escapedPattern(for: String(character)); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "%" { expression += ".*" }
            else if character == "_" { expression += "." }
            else { expression += NSRegularExpression.escapedPattern(for: String(character)) }
        }
        if escaped { expression += "\\\\" }
        return database.range(of: expression + "$", options: .regularExpression) != nil
    }

    private static func column(_ row: SchemaEngineJSON) -> SchemaEngineJSON {
        func number(_ key: String) -> SchemaEngineJSON { Double(row[key].string).map(SchemaEngineJSON.number) ?? .null }
        return .object(["name": row["name"], "data_type": row["data_type"], "is_nullable": .bool(row["nullable"].string == "YES"),
                        "column_default": row["default_value"], "is_primary_key": .bool(row["key_kind"].string == "PRI"),
                        "is_unique": .bool(row["key_kind"].string == "UNI"), "generation_expression": row["generation_expression"], "extra": row["extra"], "comment": row["comment"],
                        "numeric_precision": number("numeric_precision"), "numeric_scale": number("numeric_scale"),
                        "character_maximum_length": number("character_maximum_length"), "character_set": row["character_set"], "collation": row["collation"]])
    }
    private static func indexes(_ rows: [SchemaEngineJSON]) -> [SchemaEngineJSON] {
        let names = rows.map { $0["name"].string }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return names.map { name in
            let parts = rows.filter { $0["name"].string == name }, first = parts.first ?? .null
            return .object(["name": .string(name), "columns": .array(parts.map {
                $0["expression"].string.isEmpty ? $0["column_name"] : .string("(" + $0["expression"].string + ")")
            }), "is_unique": .bool(first["non_unique"].string == "0"), "is_primary": .bool(name == "PRIMARY"),
                "index_type": first["index_type"], "comment": first["comment"].string.isEmpty ? .null : first["comment"]])
        }
    }
    private static func hasExpressionMetadata(_ version: String) -> Bool {
        let parts = version.split(separator: ".").prefix(3).map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        return parts.lexicographicallyPrecedes([8, 0, 13]) == false
    }
    static func identifier(_ value: String) -> String { "`" + value.replacingOccurrences(of: "`", with: "``") + "`" }
    static func literal(_ value: String) -> String {
        value.isEmpty ? "''" : "CONVERT(0x" + value.utf8.map { String(format: "%02x", $0) }.joined() + " USING utf8mb4)"
    }
    private func query(_ sql: String, session: any WorkspaceSession, database: String) async throws -> [SchemaEngineJSON] {
        try Task.checkCancellation()
        let collector = SchemaComparisonCatalogRows()
        // An explicit limit overrides a server/session SQL_SELECT_LIMIT; a
        // truncated catalog must never be mistaken for absent columns/objects.
        let statement = sql.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SELECT")
            ? sql + " LIMIT 18446744073709551615" : sql
        _ = try await session.executeReadOnlyQuery(statement, database: database) { batch in await collector.append(batch) }
        try Task.checkCancellation()
        return await collector.rows
    }
}

private actor SchemaComparisonCatalogRows {
    private(set) var rows: [SchemaEngineJSON] = []
    func append(_ batch: WorkspaceDatabaseDataBatch) {
        for row in batch.rows {
            var values: [String: SchemaEngineJSON] = [:]
            for (column, cell) in zip(batch.columns, row.values) {
                switch cell {
                case .text(let value): values[column.name] = .string(value)
                case .null: values[column.name] = .null
                case .binary: values[column.name] = .null
                }
            }
            rows.append(.object(values))
        }
    }
}
