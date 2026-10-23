import Foundation
import QueryCraftFeature
import QueryCraftMariaDBTransportV4

actor MySQLWorkspaceSession: WorkspaceSession, WorkspaceSQLObjectOverviewProviding, WorkspaceNativeBulkTransferSession, WorkspaceNativeRowSourceSession {
    private let configuration: MySQLConnectionConfiguration
    private var client: MariaDBClient?
    private var cachedSchemaChoices: WorkspaceDatabaseSchemaChoices?

    init(configuration: MySQLConnectionConfiguration) {
        self.configuration = configuration
    }

    func connect() async throws {
        try await LicenseAccessGate.shared.requireDatabaseAccess()
        if await client?.isConnected() == true { return }

        let newClient = MariaDBClient(
            configuration: configuration.transportConfiguration
        )
        try await newClient.connect()
        try Task.checkCancellation()
        client = newClient
    }

    func isConnected() async -> Bool {
        await client?.isConnected() == true
    }

    func nativeBulkTransferFormat() async throws -> WorkspaceNativeBulkFormat? {
        let result = try await requireClient().query("SELECT @@GLOBAL.local_infile")
        return result.rows.first?.first == "1" ? .mysqlLocalTSV : nil
    }

    func streamTransferRows(sql: String, batchSize: Int,
                            onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void) async throws -> Int {
        try await requireClient().streamTransferRows(sql: sql, batchSize: batchSize, onBatch: onBatch)
    }

    func executeNativeBulkTransfer(sql: String, token: String,
                                   stream: WorkspaceNativeBulkStream) async throws -> Int {
        try await requireClient().loadLocal(sql: sql, token: token, stream: stream)
    }

    func fetchDatabases() async throws -> [String] {
        let result = try await requireClient().query("SHOW DATABASES")
        return result.rows.compactMap { $0.first ?? nil }
    }

    func applyQueryContext(_ context: WorkspaceQueryContext) async throws {
        guard context.schemaName == nil else {
            throw WorkspaceSessionError.queryUnavailable
        }
        if let database = context.databaseName, !database.isEmpty {
            _ = try await requireClient().query("USE \(quoteIdentifier(database))")
        }
    }

    func fetchSchemaObjectCatalog() async throws -> [WorkspaceSchemaDatabase] {
        let names = try await fetchDatabases()
        try Task.checkCancellation()
        let result = try await requireClient().query(MySQLSchemaCatalog.objectsQuery)
        try Task.checkCancellation()
        return MySQLSchemaCatalog.databases(names, rows: result.dictionaryRows)
    }

    func fetchSchemaColumns(for objects: [WorkspaceSchemaObjectReference]) async throws -> [WorkspaceSchemaObjectColumns] {
        let objects = Array(Set(objects))
        guard !objects.isEmpty else { return [] }
        let result = try await requireClient().query(MySQLSchemaCatalog.columnsQuery(objects))
        try Task.checkCancellation()
        return MySQLSchemaCatalog.columns(objects, rows: result.dictionaryRows)
    }

    func fetchObjects(
        in database: String
    ) async throws -> [WorkspaceDatabaseObject] {
        let result = try await requireClient().query(
            "SHOW FULL TABLES FROM \(quoteIdentifier(database))"
        )
        try Task.checkCancellation()

        return result.rows.compactMap { row in
            guard
                let name = row.first ?? nil,
                row.indices.contains(1),
                let rawType = row[1]
            else { return nil }
            switch rawType {
            case "BASE TABLE":
                return WorkspaceDatabaseObject(name: name, kind: .table)
            case "VIEW":
                return WorkspaceDatabaseObject(name: name, kind: .view)
            default:
                return nil
            }
        }
    }

    func fetchSQLObjectOverview(in database: String) async throws -> [WorkspaceSQLObjectOverviewEntry] {
        let rows = try await requireClient().query(
            """
            SELECT t.TABLE_NAME AS object_name, t.TABLE_TYPE AS object_kind,
                   t.TABLE_COMMENT AS object_comment, t.TABLE_ROWS AS row_count,
                   t.DATA_LENGTH + t.INDEX_LENGTH AS storage_bytes,
                   t.ENGINE AS engine, t.TABLE_COLLATION AS collation
            FROM information_schema.TABLES t
            WHERE t.TABLE_SCHEMA = \(hexStringLiteral(database))
            ORDER BY t.TABLE_NAME
            """
        ).dictionaryRows
        try Task.checkCancellation()
        return rows.compactMap { row in
            guard let name = row["object_name"] ?? nil,
                  let rawKind = row["object_kind"] ?? nil else { return nil }
            let isView = rawKind.uppercased() == "VIEW"
            return WorkspaceSQLObjectOverviewEntry(
                object: WorkspaceDatabaseObject(name: name, kind: isView ? .view : .table),
                comment: isView && row["object_comment"] == "VIEW" ? "" : (row["object_comment"] ?? nil) ?? "",
                estimatedRowCount: isView ? nil : (row["row_count"] ?? nil).flatMap(Int64.init),
                storageByteCount: isView ? nil : (row["storage_bytes"] ?? nil).flatMap(Int64.init),
                engine: isView ? nil : row["engine"] ?? nil,
                collation: isView ? nil : row["collation"] ?? nil
            )
        }
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        let qualifiedName = "\(quoteIdentifier(database)).\(quoteIdentifier(object.name))"
        let columnResult = try await requireClient().query(
            MySQLTableSchemaMetadata.columnsQuery(database: database, name: object.name)
        )
        try Task.checkCancellation()
        let columns = MySQLTableSchemaMetadata.columns(columnResult.dictionaryRows)

        let createLabel: String
        let createStatement: String
        switch object.kind {
        case .table:
            createLabel = "Create Table"
            createStatement = "SHOW CREATE TABLE \(qualifiedName)"
        case .view:
            createLabel = "Create View"
            createStatement = "SHOW CREATE VIEW \(qualifiedName)"
        case .elasticsearchIndex,
             .elasticsearchAlias,
             .elasticsearchDataStream:
            throw WorkspaceSessionError.metadataUnavailable(
                object: object.name
            )
        }
        let ddlResult = try await requireClient().query(createStatement)
        guard let ddl = ddlResult.dictionaryRows.first?[createLabel] ?? nil else {
            throw WorkspaceSessionError.metadataUnavailable(object: object.name)
        }

        let tableInformation: WorkspaceDatabaseTableInformation?
        if object.kind == .table {
            tableInformation = try await fetchTableInformation(
                database: database,
                objectName: object.name
            )
        } else {
            tableInformation = nil
        }

        return WorkspaceDatabaseObjectDetails(
            columns: columns,
            ddl: ddl,
            tableInformation: tableInformation,
            schemaChoices: await fetchSchemaChoices()
        )
    }

    func fetchSchemaChoices() async -> WorkspaceDatabaseSchemaChoices {
        if let cachedSchemaChoices { return cachedSchemaChoices }
        do {
            let engineResult = try await requireClient().query("SHOW ENGINES")
            let characterSetResult = try await requireClient().query(
                "SHOW CHARACTER SET"
            )
            let collationResult = try await requireClient().query(
                "SHOW COLLATION"
            )

            let choices = WorkspaceDatabaseSchemaChoices(
                engines: engineResult.dictionaryRows.compactMap { row in
                    guard
                        let name = row["Engine"] ?? nil,
                        (row["Support"] ?? nil) != "NO"
                    else { return nil }
                    return name
                },
                characterSets: characterSetResult.dictionaryRows.compactMap {
                    $0["Charset"] ?? nil
                },
                collations: collationResult.dictionaryRows.compactMap { row in
                    guard
                        let name = row["Collation"] ?? nil,
                        let characterSet = row["Charset"] ?? nil
                    else { return nil }
                    return WorkspaceDatabaseSchemaChoices.Collation(
                        name: name,
                        characterSet: characterSet,
                        isDefault: (row["Default"] ?? nil) == "Yes"
                    )
                }
            )
            cachedSchemaChoices = choices
            return choices
        } catch {
            cachedSchemaChoices = .empty
            return .empty
        }
    }

    func schemaEditingProvider() async -> (any DatabaseSchemaEditingProvider)? {
        MySQLSchemaEditingProvider()
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        let result = try await requireClient().query(
            "SHOW INDEX FROM \(quoteIdentifier(database)).\(quoteIdentifier(object.name))"
        )
        try Task.checkCancellation()

        return MySQLTableSchemaMetadata.indexes(result.dictionaryRows)
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
        guard offset >= 0, limit > 0 else {
            throw WorkspaceSessionError.invalidPageRequest
        }
        let queryLimit = limit + 1
        let qualifiedName = "\(quoteIdentifier(database)).\(quoteIdentifier(object.name))"
        let filterPredicate = try makeFilterPredicate(filter)
        let orderClause = switch sort {
        case .none:
            ""
        case let .ascending(columnName):
            " ORDER BY \(quoteIdentifier(columnName)) ASC"
        case let .descending(columnName):
            " ORDER BY \(quoteIdentifier(columnName)) DESC"
        }
        let result = try await requireClient().query(
            "SELECT * FROM \(qualifiedName)\(filterPredicate.sql)\(orderClause) "
                + "LIMIT \(queryLimit) OFFSET \(offset)",
            bindings: filterPredicate.bindings
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
                ? try await dataColumns(qualifiedName: qualifiedName)
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
        let qualifiedName = "\(quoteIdentifier(database)).\(quoteIdentifier(object.name))"
        let filterPredicate = try makeFilterPredicate(filter)
        let result = try await requireClient().query(
            "SELECT COUNT(*) AS row_count FROM \(qualifiedName)"
                + filterPredicate.sql,
            bindings: filterPredicate.bindings
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
        let statement = try MySQLWorkspaceDataRowInsertStatement.make(
            insert: insert
        )
        let result = try await requireClient().query(
            statement.sql,
            bindings: statement.bindings
        )
        guard let affectedRows = Int(exactly: result.affectedRows) else {
            throw WorkspaceDatabaseDataRowInsertError
                .unexpectedAffectedRows(Int.max)
        }
        return affectedRows
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
        let statement = try MySQLWorkspaceDataRowDeleteStatement.make(
            delete: delete
        )
        let result = try await requireClient().query(
            statement.sql,
            bindings: statement.bindings
        )
        guard let affectedRows = Int(exactly: result.affectedRows) else {
            throw WorkspaceDatabaseDataRowDeleteError
                .unexpectedAffectedRows(Int.max)
        }
        return affectedRows
    }

    func applyDataChanges(
        _ changes: WorkspaceDatabaseDataChangeSet
    ) async throws {
        guard !changes.isEmpty else { return }
        let client = try requireClient()
        try await MySQLWorkspaceDataChangeExecutor.apply(changes) { sql, bindings in
            if bindings.isEmpty { return try await client.query(sql).affectedRows }
            return try await client.query(sql, bindings: bindings).affectedRows
        }
    }

    func applySchemaChanges(
        _ changes: WorkspaceDatabaseSchemaChangeSet
    ) async throws {
        try await applySchemaExecutionPlan(
            MySQLSchemaEditingProvider().makeExecutionPlan(for: changes)
        )
    }

    func applySchemaExecutionPlan(
        _ plan: WorkspaceDatabaseSchemaExecutionPlan
    ) async throws {
        guard plan.dialectIdentifier == MySQLSchemaEditingProvider
            .dialectIdentifier
        else {
            throw WorkspaceSessionError.queryUnavailable
        }
        for statement in plan.statements {
            try Task.checkCancellation()
            _ = try await requireClient().query(statement.sql)
        }
    }

    func connectionID() async throws -> Int {
        try await requireClient().connectionID()
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
        let client = try requireClient()
        if let database, !database.isEmpty {
            _ = try await client.query("USE \(quoteIdentifier(database))")
        }
        _ = try await client.query("START TRANSACTION READ ONLY")
        do {
            let result = try await executeQuery(
                sql,
                maximumRows: maximumRows,
                onBatch: onBatch
            )
            _ = try await client.query("ROLLBACK")
            return result.withTransactionState(.autoCommit)
        } catch {
            _ = try? await client.query("ROLLBACK")
            throw error
        }
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
        if let database, !database.isEmpty {
            _ = try await requireClient().query("USE \(quoteIdentifier(database))")
        }
        return try await executeQuery(
            sql,
            maximumRows: kind == .read ? maximumRows : nil,
            onBatch: onBatch
        )
    }

    func cancelQuery(connectionID: Int) async throws {
        guard connectionID > 0 else {
            throw WorkspaceSessionError.invalidConnectionID
        }
        _ = try await requireClient().query("KILL QUERY \(connectionID)")
    }

    func close() async {
        cachedSchemaChoices = nil
        let client = self.client
        self.client = nil
        await client?.close()
    }

    private func updateDataRow(
        _ update: WorkspaceDatabaseDataRowUpdate
    ) async throws -> Int {
        let statement = try MySQLWorkspaceDataCellUpdateStatement.make(
            rowUpdate: update
        )
        let result = try await requireClient().query(
            statement.sql,
            bindings: statement.bindings
        )
        guard let affectedRows = Int(exactly: result.affectedRows) else {
            throw WorkspaceDatabaseDataCellEditError
                .unexpectedAffectedRows(Int.max)
        }
        return affectedRows
    }

    private func executeQuery(
        _ sql: String,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        let client = try requireClient()
        if let maximumRows {
            _ = try await client.query(
                "SET SESSION SQL_SELECT_LIMIT = \(maximumRows)"
            )
        }
        do {
            let execution = try await client.queryStream(sql, onBatch: onBatch)
            if maximumRows != nil {
                _ = try await client.query("SET SESSION SQL_SELECT_LIMIT = DEFAULT")
            }
            return WorkspaceQueryExecutionResult(
                columns: execution.columns,
                rowCount: execution.columns.isEmpty ? Int(clamping: execution.affectedRows) : execution.rowCount,
                transactionState: execution.transactionState
            )
        } catch {
            if maximumRows != nil {
                _ = try? await client.query("SET SESSION SQL_SELECT_LIMIT = DEFAULT")
            }
            throw error
        }
    }

    private func fetchTableInformation(
        database: String,
        objectName: String
    ) async throws -> WorkspaceDatabaseTableInformation? {
        let tableResult = try await requireClient().query(
            MySQLTableSchemaMetadata.informationQuery(database: database, name: objectName)
        )
        return tableResult.dictionaryRows.first.map(MySQLTableSchemaMetadata.information)
    }

    private func dataColumns(
        qualifiedName: String
    ) async throws -> [WorkspaceDatabaseDataColumn] {
        let result = try await requireClient().query(
            "SHOW COLUMNS FROM \(qualifiedName)"
        )
        return result.dictionaryRows.enumerated().compactMap { index, row in
            guard let name = row["Field"] ?? nil else { return nil }
            return WorkspaceDatabaseDataColumn(id: index, name: name)
        }
    }

    private func makeFilterPredicate(_ filter: WorkspaceDatabaseDataFilter) throws -> MySQLDataFilterPredicate {
        try MySQLDataFilterPredicate.make(filter)
    }

    private func requireClient() throws -> MariaDBClient {
        guard let client else { throw WorkspaceSessionError.notConnected }
        return client
    }

    private func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    private func hexStringLiteral(_ value: String) -> String {
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        return "CONVERT(0x\(hex) USING utf8mb4)"
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
