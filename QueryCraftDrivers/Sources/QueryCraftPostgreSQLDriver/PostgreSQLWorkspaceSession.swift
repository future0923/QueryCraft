import Foundation
import QueryCraftFeature

actor PostgreSQLWorkspaceSession: WorkspaceSession {
    private struct ObjectIdentity: Sendable {
        let schema: String
        let name: String
    }

    private struct MutationStatement: Sendable {
        let sql: String
    }

    private let configuration: PostgreSQLConnectionConfiguration
    private var client: LibPQClient?
    private var capabilities = PostgreSQLCapabilities.unknown
    private var currentDatabase: String
    private var transactionState = WorkspaceQueryTransactionState.disconnected
    private var objectIdentities: [String: ObjectIdentity] = [:]

    init(configuration: PostgreSQLConnectionConfiguration) {
        self.configuration = configuration
        currentDatabase = configuration.database
    }

    func connect() async throws {
        try await LicenseAccessGate.shared.requireDatabaseAccess()
        if await client?.isConnected() == true { return }

        let newClient = LibPQClient(configuration: configuration)
        try await newClient.connect()
        let serverVersion = await newClient.serverVersionNumber()
        guard serverVersion > 0 else {
            await newClient.close()
            throw WorkspaceSessionError.metadataUnavailable(
                object: "server_version_num"
            )
        }
        let databaseRows = try await newClient.query(
            "SELECT current_database()::text AS database_name"
        )
        currentDatabase = (databaseRows.dictionaryRows.first?["database_name"]
            ?? nil) ?? configuration.database
        try Task.checkCancellation()

        capabilities = PostgreSQLCapabilities(serverVersion: Int(serverVersion))
        transactionState = .autoCommit
        client = newClient
    }

    func isConnected() async -> Bool {
        await client?.isConnected() == true
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await requireClient().query(
            "SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname"
        )
        return result.rows.compactMap { $0.first ?? nil }
    }

    func fetchSchemas(in database: String) async throws -> [String] {
        try requireCurrentDatabase(database)
        let result = try await requireClient().query(
            """
            SELECT n.nspname::text
            FROM pg_catalog.pg_namespace n
            WHERE n.nspname NOT LIKE 'pg!_%' ESCAPE '!'
              AND n.nspname <> 'information_schema'
              AND has_schema_privilege(current_user, n.oid, 'USAGE')
            ORDER BY n.nspname
            """
        )
        return result.rows.compactMap { $0.first ?? nil }
    }

    func applyQueryContext(_ context: WorkspaceQueryContext) async throws {
        try requireCurrentDatabase(context.databaseName ?? currentDatabase)
        if let schema = context.schemaName, !schema.isEmpty {
            _ = try await requireClient().query(
                "SELECT set_config('search_path', \(Self.literal(schema)), false)"
            )
        } else {
            _ = try await requireClient().query("RESET search_path")
        }
    }

    func schemaEditingProvider() async -> (any DatabaseSchemaEditingProvider)? {
        PostgreSQLSchemaEditingProvider(capabilities: capabilities)
    }

    func fetchSchemaObjectCatalog() async throws -> [WorkspaceSchemaDatabase] {
        let objects = try await fetchObjects(in: currentDatabase)
        return [
            WorkspaceSchemaDatabase(
                name: currentDatabase,
                objects: objects.map {
                    WorkspaceSchemaObject(
                        name: $0.name,
                        kind: $0.kind,
                        columns: []
                    )
                }
            ),
        ]
    }

    func fetchSchemaColumns(
        for objects: [WorkspaceSchemaObjectReference]
    ) async throws -> [WorkspaceSchemaObjectColumns] {
        var result: [WorkspaceSchemaObjectColumns] = []
        result.reserveCapacity(objects.count)
        for reference in Array(Set(objects)) {
            try Task.checkCancellation()
            let identity = identity(for: reference.objectName)
            let rows = try await requireClient().query(
                """
                SELECT
                    column_name::text AS column_name,
                    (data_type || CASE
                        WHEN udt_name <> data_type THEN ' (' || udt_name || ')'
                        ELSE ''
                    END)::text AS column_type,
                    ordinal_position::text AS ordinal_position
                FROM information_schema.columns
                WHERE table_schema = \(Self.literal(identity.schema))
                  AND table_name = \(Self.literal(identity.name))
                ORDER BY ordinal_position
                """
            ).dictionaryRows
            let columns = rows.compactMap {
                row -> WorkspaceSchemaColumn? in
                guard
                    let name = row["column_name"] ?? nil,
                    let type = row["column_type"] ?? nil,
                    let ordinalText = row["ordinal_position"] ?? nil,
                    let ordinal = Int(ordinalText)
                else { return nil }
                return WorkspaceSchemaColumn(
                    name: name,
                    type: type,
                    ordinalPosition: ordinal
                )
            }
            result.append(
                WorkspaceSchemaObjectColumns(
                    reference: reference,
                    columns: columns
                )
            )
        }
        return result
    }

    func fetchObjects(
        in database: String
    ) async throws -> [WorkspaceDatabaseObject] {
        try requireCurrentDatabase(database)
        let rows = try await requireClient().query(
            """
            SELECT
                n.nspname::text AS schema_name,
                c.relname::text AS object_name,
                c.relkind::text AS object_kind
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND n.nspname NOT LIKE 'pg!_%' ESCAPE '!'
              AND n.nspname <> 'information_schema'
              AND has_schema_privilege(current_user, n.oid, 'USAGE')
            ORDER BY n.nspname, c.relname
            """
        ).dictionaryRows

        objectIdentities.removeAll(keepingCapacity: true)
        return rows.compactMap { row in
            guard
                let schema = row["schema_name"] ?? nil,
                let name = row["object_name"] ?? nil,
                let rawKind = row["object_kind"] ?? nil
            else { return nil }
            let kind: WorkspaceDatabaseObjectKind = rawKind == "v" || rawKind == "m"
                ? .view
                : .table
            let displayName = "\(schema).\(name)"
            objectIdentities[displayName] = ObjectIdentity(
                schema: schema,
                name: name
            )
            return WorkspaceDatabaseObject(name: displayName, kind: kind)
        }
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        try requireCurrentDatabase(database)
        let identity = identity(for: object.name)
        let rows = try await requireClient().query(
            """
            SELECT
                c.column_name::text AS column_name,
                c.data_type::text AS column_type,
                c.collation_name::text AS collation_name,
                c.is_nullable::text AS is_nullable,
                CASE WHEN pk.column_name IS NULL THEN '' ELSE 'PRI' END::text AS column_key,
                c.column_default::text AS column_default,
                CASE
                    WHEN c.is_identity = 'YES' THEN 'IDENTITY'
                    WHEN c.is_generated = 'ALWAYS' THEN 'STORED GENERATED'
                    ELSE ''
                END::text AS extra,
                COALESCE(pgd.description, '')::text AS column_comment,
                COALESCE(c.generation_expression, '')::text AS generation_expression
            FROM information_schema.columns c
            LEFT JOIN pg_catalog.pg_statio_all_tables st
              ON st.schemaname = c.table_schema AND st.relname = c.table_name
            LEFT JOIN pg_catalog.pg_description pgd
              ON pgd.objoid = st.relid AND pgd.objsubid = c.ordinal_position
            LEFT JOIN (
                SELECT kcu.table_schema, kcu.table_name, kcu.column_name
                FROM information_schema.table_constraints tc
                JOIN information_schema.key_column_usage kcu
                  ON kcu.constraint_name = tc.constraint_name
                 AND kcu.constraint_schema = tc.constraint_schema
                WHERE tc.constraint_type = 'PRIMARY KEY'
            ) pk ON pk.table_schema = c.table_schema
                AND pk.table_name = c.table_name
                AND pk.column_name = c.column_name
            WHERE c.table_schema = \(Self.literal(identity.schema))
              AND c.table_name = \(Self.literal(identity.name))
            ORDER BY c.ordinal_position
            """
        )
        let columns = rows.dictionaryRows.compactMap(Self.makeColumn)
        let ddl: String
        if object.kind == .view {
            let ddlRows = try await requireClient().query(
                """
                SELECT pg_get_viewdef(
                    \(Self.literal(Self.qualified(identity)))::regclass,
                    true
                )::text AS view_definition
                """
            )
            let body = (ddlRows.dictionaryRows.first?["view_definition"] ?? nil) ?? ""
            ddl = "CREATE VIEW \(Self.quotedQualified(identity)) AS\n\(body);"
        } else {
            let definitions = columns.map { column in
                var definition = "    \(Self.identifier(column.name)) \(column.type)"
                if let defaultValue = column.defaultValue {
                    definition += " DEFAULT \(defaultValue)"
                }
                if !column.isNullable { definition += " NOT NULL" }
                return definition
            }
            ddl = "CREATE TABLE \(Self.quotedQualified(identity)) (\n"
                + definitions.joined(separator: ",\n") + "\n);"
        }
        return WorkspaceDatabaseObjectDetails(columns: columns, ddl: ddl)
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        try requireCurrentDatabase(database)
        let identity = identity(for: object.name)
        let rows = try await requireClient().query(
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
            WHERE ns.nspname = \(Self.literal(identity.schema))
              AND tbl.relname = \(Self.literal(identity.name))
            ORDER BY i.indisprimary DESC, idx.relname, ord.ordinality
            """
        ).dictionaryRows

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
                Self.pgBool(uniqueText),
                Self.pgBool(primaryText),
                type,
                (row["index_comment"] ?? nil) ?? ""
            )
            columnsByIndex[name, default: []].append(
                WorkspaceDatabaseIndexColumn(
                    sequence: sequence,
                    name: column,
                    prefixLength: nil,
                    direction: Self.pgBool(descendingText) ? "D" : "A",
                    isExpression: Self.pgBool(expressionText)
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

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        try await fetchDataPage(
            for: object,
            in: database,
            offset: offset,
            limit: limit,
            sort: sort,
            filter: .empty,
            onBatch: onBatch
        )
    }

    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult {
        try requireCurrentDatabase(database)
        guard offset >= 0, limit > 0, limit < Int.max else {
            throw WorkspaceSessionError.invalidPageRequest
        }
        let identity = identity(for: object.name)
        let orderClause = switch sort {
        case .none: ""
        case .ascending(let columnName):
            " ORDER BY \(Self.identifier(columnName)) ASC"
        case .descending(let columnName):
            " ORDER BY \(Self.identifier(columnName)) DESC"
        }
        let predicate = try Self.filterPredicate(filter)
        let result = try await requireClient().query(
            "SELECT * FROM \(Self.quotedQualified(identity))"
                + predicate + orderClause
                + " LIMIT \(limit + 1) OFFSET \(offset)"
        )
        try Task.checkCancellation()
        let columns = result.columns.enumerated().map { index, name in
            let origin = (result.columnOrigins.indices.contains(index)
                ? result.columnOrigins[index]
                : nil).map {
                    WorkspaceDatabaseDataColumn.Origin(
                        schemaName: $0.schemaName,
                        tableName: $0.tableName,
                        columnName: $0.columnName
                    )
                }
            return WorkspaceDatabaseDataColumn(
                id: index,
                name: name,
                origin: origin
            )
        }
        let rows = result.rows.prefix(limit).enumerated().map { index, row in
            WorkspaceDatabaseDataRow(
                id: offset + index,
                values: row.map { value in
                    value.map(WorkspaceDatabaseDataCell.text)
                        ?? WorkspaceDatabaseDataCell.null
                }
            )
        }
        if !rows.isEmpty || !columns.isEmpty {
            await onBatch(WorkspaceDatabaseDataBatch(columns: columns, rows: rows))
        }
        return WorkspaceDatabaseDataFetchResult(
            columns: columns.isEmpty
                ? try await dataColumns(for: identity)
                : columns,
            hasNextPage: result.rows.count > limit
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        try await fetchDataCount(for: object, in: database, filter: .empty)
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String,
        filter: WorkspaceDatabaseDataFilter
    ) async throws -> Int {
        try requireCurrentDatabase(database)
        let identity = identity(for: object.name)
        let predicate = try Self.filterPredicate(filter)
        let result = try await requireClient().query(
            "SELECT COUNT(*)::text AS row_count FROM "
                + Self.quotedQualified(identity) + predicate
        )
        guard
            let value = result.dictionaryRows.first?["row_count"] ?? nil,
            let count = Int(value)
        else {
            throw WorkspaceSessionError.metadataUnavailable(object: object.name)
        }
        return count
    }

    func updateDataCell(
        _ update: WorkspaceDatabaseDataCellUpdate
    ) async throws -> Int {
        try await updateDataRow(
            WorkspaceDatabaseDataRowUpdate(
                selection: update.selection,
                primaryKey: update.primaryKey,
                assignments: [update]
            )
        )
    }

    func updateDataCells(
        _ updates: [WorkspaceDatabaseDataCellUpdate]
    ) async throws {
        guard !updates.isEmpty else { return }
        try await applyDataChanges(
            WorkspaceDatabaseDataChangeSet(
                updates: updates,
                inserts: [],
                deletes: []
            )
        )
    }

    func insertDataRow(
        _ insert: WorkspaceDatabaseDataRowInsert
    ) async throws -> Int {
        try requireCurrentDatabase(insert.selection.databaseName)
        return try await executeMutation(Self.insertStatement(insert))
    }

    func insertDataRows(
        _ inserts: [WorkspaceDatabaseDataRowInsert]
    ) async throws {
        guard !inserts.isEmpty else { return }
        try await applyDataChanges(
            WorkspaceDatabaseDataChangeSet(
                updates: [],
                inserts: inserts,
                deletes: []
            )
        )
    }

    func deleteDataRow(
        _ delete: WorkspaceDatabaseDataRowDelete
    ) async throws -> Int {
        try requireCurrentDatabase(delete.selection.databaseName)
        return try await executeMutation(Self.deleteStatement(delete))
    }

    func applyDataChanges(
        _ changes: WorkspaceDatabaseDataChangeSet
    ) async throws {
        guard !changes.isEmpty else { return }
        guard changes.hasConsistentSelection, let selection = changes.selection else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }
        try requireCurrentDatabase(selection.databaseName)
        let client = try requireClient()
        _ = try await client.query("BEGIN")
        do {
            for delete in changes.deletes {
                try Task.checkCancellation()
                let affectedRows = try await executeMutation(
                    Self.deleteStatement(delete)
                )
                guard affectedRows == 1 else {
                    if affectedRows == 0 {
                        throw WorkspaceDatabaseDataRowDeleteError.rowChanged
                    }
                    throw WorkspaceDatabaseDataRowDeleteError
                        .unexpectedAffectedRows(affectedRows)
                }
            }
            for update in changes.rowUpdates {
                try Task.checkCancellation()
                let affectedRows = try await updateDataRow(update)
                guard affectedRows == 1 else {
                    if affectedRows == 0 {
                        throw WorkspaceDatabaseDataCellEditError.rowChanged
                    }
                    throw WorkspaceDatabaseDataCellEditError
                        .unexpectedAffectedRows(affectedRows)
                }
            }
            for insert in changes.inserts {
                try Task.checkCancellation()
                let affectedRows = try await executeMutation(
                    Self.insertStatement(insert)
                )
                guard affectedRows == 1 else {
                    throw WorkspaceDatabaseDataRowInsertError
                        .unexpectedAffectedRows(affectedRows)
                }
            }
            _ = try await client.query("COMMIT")
        } catch {
            _ = try? await client.query("ROLLBACK")
            throw error
        }
    }

    func applySchemaChanges(
        _ changes: WorkspaceDatabaseSchemaChangeSet
    ) async throws {
        try await applySchemaExecutionPlan(
            PostgreSQLSchemaEditingProvider(capabilities: capabilities)
                .makeExecutionPlan(for: changes)
        )
    }

    func applySchemaExecutionPlan(
        _ plan: WorkspaceDatabaseSchemaExecutionPlan
    ) async throws {
        guard plan.dialectIdentifier == PostgreSQLSchemaEditingProvider
            .dialectIdentifier
        else {
            throw WorkspaceSessionError.queryUnavailable
        }
        let usesTransaction = plan.transactionMode == .transaction
        if usesTransaction {
            _ = try await requireClient().query("BEGIN")
        }
        do {
            for statement in plan.statements {
                try Task.checkCancellation()
                _ = try await requireClient().query(statement.sql)
            }
            if usesTransaction {
                _ = try await requireClient().query("COMMIT")
            }
        } catch {
            if usesTransaction {
                _ = try? await requireClient().query("ROLLBACK")
            }
            throw error
        }
    }

    func connectionID() async throws -> Int {
        let rows = try await requireClient().query(
            "SELECT pg_backend_pid()::text AS connection_id"
        )
        guard
            let value = rows.dictionaryRows.first?["connection_id"] ?? nil,
            let id = Int(value)
        else { throw WorkspaceSessionError.invalidConnectionID }
        return id
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        try await executeReadOnlyQuery(
            sql,
            database: database,
            maximumRows: nil,
            onBatch: onBatch
        )
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        try requireCurrentDatabase(database ?? currentDatabase)
        let boundedSQL: String
        if let maximumRows, maximumRows >= 0 {
            boundedSQL = "SELECT * FROM (\(Self.withoutTrailingSemicolon(sql))) AS querycraft_result LIMIT \(maximumRows)"
        } else {
            boundedSQL = sql
        }
        return try await executeQuery(boundedSQL, onBatch: onBatch)
            .withTransactionState(.autoCommit)
    }

    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        try await executeStatement(
            sql,
            kind: kind,
            database: database,
            maximumRows: nil,
            onBatch: onBatch
        )
    }

    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        if case .read = kind {
            return try await executeReadOnlyQuery(
                sql,
                database: database,
                maximumRows: maximumRows,
                onBatch: onBatch
            )
        }
        try requireCurrentDatabase(database ?? currentDatabase)
        let result = try await executeQuery(sql, onBatch: onBatch)
        transactionState = try transactionState.afterSuccessfulStatement(kind)
        return result.withTransactionState(transactionState)
    }

    func cancelQuery(connectionID: Int) async throws {
        guard connectionID > 0 else {
            throw WorkspaceSessionError.invalidConnectionID
        }
        _ = try await requireClient().query(
            "SELECT pg_cancel_backend(\(connectionID))::text"
        )
    }

    func close() async {
        transactionState = .disconnected
        capabilities = .unknown
        objectIdentities.removeAll()
        let client = self.client
        self.client = nil
        await client?.close()
    }

    private func updateDataRow(
        _ update: WorkspaceDatabaseDataRowUpdate
    ) async throws -> Int {
        try requireCurrentDatabase(update.selection.databaseName)
        return try await executeMutation(Self.updateStatement(update))
    }

    private func executeMutation(
        _ statement: MutationStatement
    ) async throws -> Int {
        let result = try await requireClient().query(statement.sql)
        return result.affectedRows
    }

    private func executeQuery(
        _ sql: String,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        let result = try await requireClient().query(sql)
        try Task.checkCancellation()
        let columns = result.columns.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
        }
        let rows = result.rows.enumerated().map { index, row in
            WorkspaceDatabaseDataRow(
                id: index,
                values: row.map { value in
                    value.map(WorkspaceDatabaseDataCell.text)
                        ?? WorkspaceDatabaseDataCell.null
                }
            )
        }
        if !columns.isEmpty || !rows.isEmpty {
            try await onBatch(
                WorkspaceDatabaseDataBatch(columns: columns, rows: rows)
            )
        }
        return WorkspaceQueryExecutionResult(
            columns: columns,
            rowCount: rows.isEmpty ? result.affectedRows : rows.count,
            transactionState: transactionState
        )
    }

    private func dataColumns(
        for identity: ObjectIdentity
    ) async throws -> [WorkspaceDatabaseDataColumn] {
        let rows = try await requireClient().query(
            """
            SELECT column_name::text AS column_name, udt_name::text AS data_type
            FROM information_schema.columns
            WHERE table_schema = \(Self.literal(identity.schema))
              AND table_name = \(Self.literal(identity.name))
            ORDER BY ordinal_position
            """
        ).dictionaryRows
        return rows.enumerated().compactMap { index, row in
            guard let name = row["column_name"] ?? nil else { return nil }
            return WorkspaceDatabaseDataColumn(
                id: index,
                name: name,
                type: row["data_type"] ?? nil
            )
        }
    }

    private func requireClient() throws -> LibPQClient {
        guard let client else { throw WorkspaceSessionError.notConnected }
        return client
    }

    private func requireCurrentDatabase(_ database: String) throws {
        guard database == currentDatabase else {
            throw WorkspaceSessionError.metadataUnavailable(object: database)
        }
    }

    private func identity(for displayName: String) -> ObjectIdentity {
        if let identity = objectIdentities[displayName] { return identity }
        guard let separator = displayName.firstIndex(of: ".") else {
            return ObjectIdentity(schema: "public", name: displayName)
        }
        return ObjectIdentity(
            schema: String(displayName[..<separator]),
            name: String(displayName[displayName.index(after: separator)...])
        )
    }

    private static func makeColumn(
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

    private static func filterPredicate(
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

    private static func updateStatement(
        _ update: WorkspaceDatabaseDataRowUpdate
    ) throws -> MutationStatement {
        guard update.selection.kind == .table else {
            throw WorkspaceDatabaseDataCellEditError.tableRequired
        }
        guard !update.primaryKey.isEmpty else {
            throw WorkspaceDatabaseDataCellEditError.primaryKeyRequired
        }
        guard
            !update.assignments.isEmpty,
            update.assignments.allSatisfy({
                $0.selection == update.selection
                    && $0.primaryKey == update.primaryKey
            })
        else {
            throw WorkspaceDatabaseDataCellEditError.editingContextChanged
        }

        let assignments = try update.assignments.map { assignment in
            if assignment.assignment == .useDefault {
                return "\(identifier(assignment.columnName)) = DEFAULT"
            }
            let value = try sqlLiteral(assignment.newValue)
            return "\(identifier(assignment.columnName)) = \(value)"
        }
        let predicates = try update.primaryKey.map {
            "\(identifier($0.columnName)) = \(try sqlLiteral($0.value))"
        }
        return MutationStatement(
            sql: "UPDATE \(qualifiedTable(update.selection)) SET "
                + assignments.joined(separator: ", ")
                + " WHERE " + predicates.joined(separator: " AND ")
        )
    }

    private static func insertStatement(
        _ insert: WorkspaceDatabaseDataRowInsert
    ) throws -> MutationStatement {
        guard insert.selection.kind == .table else {
            throw WorkspaceDatabaseDataRowInsertError.tableRequired
        }
        guard !insert.values.isEmpty else {
            return MutationStatement(
                sql: "INSERT INTO \(qualifiedTable(insert.selection)) DEFAULT VALUES"
            )
        }
        let columns = insert.values.map { identifier($0.columnName) }
        let values = try insert.values.map { try sqlLiteral($0.value) }
        return MutationStatement(
            sql: "INSERT INTO \(qualifiedTable(insert.selection)) ("
                + columns.joined(separator: ", ") + ") VALUES ("
                + values.joined(separator: ", ") + ")"
        )
    }

    private static func deleteStatement(
        _ delete: WorkspaceDatabaseDataRowDelete
    ) throws -> MutationStatement {
        guard delete.selection.kind == .table else {
            throw WorkspaceDatabaseDataRowDeleteError.tableRequired
        }
        guard !delete.conditions.isEmpty else {
            throw WorkspaceDatabaseDataRowDeleteError.primaryKeyRequired
        }
        let predicates = try delete.conditions.map {
            "\(identifier($0.columnName)) = \(try sqlLiteral($0.value))"
        }
        return MutationStatement(
            sql: "DELETE FROM \(qualifiedTable(delete.selection)) WHERE "
                + predicates.joined(separator: " AND ")
        )
    }

    private static func sqlLiteral(
        _ cell: WorkspaceDatabaseDataCell
    ) throws -> String {
        switch cell {
        case .null:
            return "NULL"
        case .text(let value):
            return literal(value)
        case .binary:
            throw WorkspaceDatabaseDataCellEditError.binaryValueUnavailable
        }
    }

    private static func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private static func qualifiedTable(
        _ selection: WorkspaceDatabaseObjectSelection
    ) -> String {
        let parts = splitObjectName(selection.objectName)
        return "\(identifier(parts.schema)).\(identifier(parts.name))"
    }

    private static func splitObjectName(
        _ value: String
    ) -> (schema: String, name: String) {
        guard let separator = value.firstIndex(of: ".") else {
            return ("public", value)
        }
        return (
            String(value[..<separator]),
            String(value[value.index(after: separator)...])
        )
    }

    private static func pgBool(_ value: String) -> Bool {
        value == "true" || value == "t" || value == "1"
    }

    private static func withoutTrailingSemicolon(_ sql: String) -> String {
        var value = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.last == ";" {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private static func literal(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }

    private static func identifier(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func qualified(_ identity: ObjectIdentity) -> String {
        "\(identity.schema).\(identity.name)"
    }

    private static func quotedQualified(_ identity: ObjectIdentity) -> String {
        "\(identifier(identity.schema)).\(identifier(identity.name))"
    }
}

private extension WorkspaceQueryExecutionResult {
    func withTransactionState(
        _ transactionState: WorkspaceQueryTransactionState
    ) -> WorkspaceQueryExecutionResult {
        WorkspaceQueryExecutionResult(
            columns: columns,
            rowCount: rowCount,
            transactionState: transactionState
        )
    }
}
