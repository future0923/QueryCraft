import Foundation
import QueryCraftFeature

actor PostgreSQLWorkspaceSession: WorkspaceSession, WorkspaceSQLObjectOverviewProviding, WorkspaceNativeBulkTransferSession, WorkspaceNativeCopySourceSession, WorkspaceNativeRowSourceSession {
    private struct ObjectIdentity: Sendable {
        let schema: String
        let name: String
    }

    private typealias MutationStatement = PostgreSQLDataMutation.Statement

    private let configuration: PostgreSQLConnectionConfiguration
    private var client: LibPQClient?
    private var capabilities = PostgreSQLCapabilities.unknown
    private var currentDatabase: String
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
        client = newClient
    }

    func isConnected() async -> Bool {
        await client?.isConnected() == true
    }

    func nativeBulkTransferFormat() async throws -> WorkspaceNativeBulkFormat? { .postgresqlCopyText }

    func executeNativeBulkTransfer(sql: String, token: String,
                                   stream: WorkspaceNativeBulkStream) async throws -> Int {
        try await requireClient().copyFrom(sql: sql, stream: stream)
    }

    func executeNativeCopyOut(sql: String, stream: WorkspaceNativeBulkStream,
                              onProgress: @escaping @Sendable (Int) async -> Void) async throws -> Int {
        try await requireClient().copyTo(sql: sql, stream: stream, onProgress: onProgress)
    }

    func streamTransferRows(sql: String, batchSize: Int,
                            onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> Int {
        try await requireClient().streamTransferRows(sql: sql, batchSize: batchSize, onBatch: onBatch)
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
            PostgreSQLCatalog.schemasQuery
        )
        return result.rows.compactMap { $0.first ?? nil }
    }

    func applyQueryContext(_ context: WorkspaceQueryContext) async throws {
        try requireCurrentDatabase(context.databaseName ?? currentDatabase)
        if let schema = context.schemaName, !schema.isEmpty {
            _ = try await requireClient().query(
                PostgreSQLCatalog.searchPathQuery(schema: schema, local: false)
            )
        } else {
            _ = try await requireClient().query("RESET search_path")
        }
    }

    func schemaEditingProvider() async -> (any DatabaseSchemaEditingProvider)? {
        PostgreSQLSchemaEditingProvider(capabilities: capabilities)
    }

    func fetchSchemaObjectCatalog() async throws -> [WorkspaceSchemaDatabase] {
        try requireCurrentDatabase(currentDatabase)
        let rows = try await requireClient().query(
            PostgreSQLCatalog.objectsQuery
        ).dictionaryRows
        try Task.checkCancellation()
        objectIdentities.removeAll(keepingCapacity: true)
        let objects = rows.compactMap { row -> WorkspaceSchemaObject? in
            guard
                let schema = row["schema_name"] ?? nil,
                let name = row["object_name"] ?? nil,
                let rawKind = row["object_kind"] ?? nil
            else { return nil }
            let displayName = "\(schema).\(name)"
            objectIdentities[displayName] = ObjectIdentity(schema: schema, name: name)
            return WorkspaceSchemaObject(
                name: displayName,
                kind: rawKind == "v" || rawKind == "m" ? .view : .table,
                columns: [],
                comment: (row["object_comment"] ?? nil) ?? ""
            )
        }
        return [
            WorkspaceSchemaDatabase(
                name: currentDatabase,
                objects: objects
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
                    c.column_name::text AS column_name,
                    (c.data_type || CASE
                        WHEN c.udt_name <> c.data_type THEN ' (' || c.udt_name || ')'
                        ELSE ''
                    END)::text AS column_type,
                    c.ordinal_position::text AS ordinal_position,
                    COALESCE(pgd.description, '')::text AS column_comment
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
                WHERE c.table_schema = \(Self.literal(identity.schema))
                  AND c.table_name = \(Self.literal(identity.name))
                ORDER BY c.ordinal_position
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
                    ordinalPosition: ordinal,
                    comment: (row["column_comment"] ?? nil) ?? ""
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

    func fetchSQLObjectOverview(in database: String) async throws -> [WorkspaceSQLObjectOverviewEntry] {
        try requireCurrentDatabase(database)
        let rows = try await requireClient().query(
            """
            SELECT n.nspname::text AS schema_name, c.relname::text AS object_name,
                   c.relkind::text AS object_kind,
                   obj_description(c.oid, 'pg_class') AS object_comment,
                   CASE WHEN c.relkind IN ('r', 'm') AND c.reltuples >= 0
                        THEN c.reltuples::bigint::text END AS row_count,
                   CASE WHEN c.relkind IN ('r', 'm')
                        THEN pg_total_relation_size(c.oid)::text END AS storage_bytes
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v', 'm', 'f')
              AND n.nspname NOT LIKE 'pg!_%' ESCAPE '!'
              AND n.nspname <> 'information_schema'
              AND has_schema_privilege(current_user, n.oid, 'USAGE')
            ORDER BY n.nspname, c.relname
            """
        ).dictionaryRows
        try Task.checkCancellation()
        objectIdentities.removeAll(keepingCapacity: true)
        return rows.compactMap { row in
            guard let schema = row["schema_name"] ?? nil,
                  let name = row["object_name"] ?? nil,
                  let rawKind = row["object_kind"] ?? nil else { return nil }
            let displayName = "\(schema).\(name)"
            objectIdentities[displayName] = ObjectIdentity(schema: schema, name: name)
            return WorkspaceSQLObjectOverviewEntry(
                object: WorkspaceDatabaseObject(name: displayName, kind: rawKind == "v" || rawKind == "m" ? .view : .table),
                comment: (row["object_comment"] ?? nil) ?? "",
                estimatedRowCount: (row["row_count"] ?? nil).flatMap(Int64.init),
                storageByteCount: (row["storage_bytes"] ?? nil).flatMap(Int64.init)
            )
        }
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        try requireCurrentDatabase(database)
        let identity = identity(for: object.name)
        let rows = try await requireClient().query(
            PostgreSQLCatalog.columnsQuery(schema: identity.schema, name: identity.name)
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
            ddl = PostgreSQLSchemaMetadata.ddl(schema: identity.schema, name: identity.name, columns: columns)
        }
        return WorkspaceDatabaseObjectDetails(columns: columns, ddl: ddl)
    }

    func fetchIndexes(for object: WorkspaceDatabaseObject, in database: String) async throws -> [WorkspaceDatabaseIndex] {
        try requireCurrentDatabase(database)
        let identity = identity(for: object.name)
        let rows = try await requireClient().query(PostgreSQLSchemaMetadata.indexesQuery(schema: identity.schema, name: identity.name))
        return PostgreSQLSchemaMetadata.indexes(rows.dictionaryRows)
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
        let columns = result.workspaceColumns
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
        return try await executeMutation(insertStatement(insert))
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
        return try await executeMutation(deleteStatement(delete))
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
        let target = identity(for: selection.objectName)
        try await PostgreSQLDataMutation.apply(changes, table: .init(schema: target.schema, name: target.name)) { sql in
            try await client.query(sql).affectedRows
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
        let client = try requireClient()
        try await PostgreSQLSchemaExecutor.apply(plan) { sql in _ = try await client.query(sql) }
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
        return try await executeQuery(sql, onBatch: onBatch)
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
        return try await executeMutation(updateStatement(update))
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
        let columns = result.workspaceColumns
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
            transactionState: result.transactionState
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
        let object = WorkspaceDatabaseObject(name: displayName, kind: .table)
        return ObjectIdentity(schema: object.schemaName ?? "public", name: object.nameWithinSchema)
    }

    private static func makeColumn(_ row: [String: String?]) -> WorkspaceDatabaseColumn? { PostgreSQLCatalog.column(row) }

    private static func filterPredicate(_ filter: WorkspaceDatabaseDataFilter) throws -> String { try PostgreSQLCatalog.filterPredicate(filter) }

    private func updateStatement(_ change: WorkspaceDatabaseDataRowUpdate) throws -> MutationStatement {
        let target = identity(for: change.selection.objectName)
        return try PostgreSQLDataMutation.updateStatement(change, table: .init(schema: target.schema, name: target.name))
    }

    private func insertStatement(_ change: WorkspaceDatabaseDataRowInsert) throws -> MutationStatement {
        let target = identity(for: change.selection.objectName)
        return try PostgreSQLDataMutation.insertStatement(change, table: .init(schema: target.schema, name: target.name))
    }

    private func deleteStatement(_ change: WorkspaceDatabaseDataRowDelete) throws -> MutationStatement {
        let target = identity(for: change.selection.objectName)
        return try PostgreSQLDataMutation.deleteStatement(change, table: .init(schema: target.schema, name: target.name))
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

    private static func literal(_ value: String) -> String { PostgreSQLCatalog.literal(value) }
    private static func identifier(_ value: String) -> String { PostgreSQLCatalog.identifier(value) }

    private static func qualified(_ identity: ObjectIdentity) -> String {
        "\(identity.schema).\(identity.name)"
    }

    private static func quotedQualified(_ identity: ObjectIdentity) -> String {
        "\(identifier(identity.schema)).\(identifier(identity.name))"
    }
}
