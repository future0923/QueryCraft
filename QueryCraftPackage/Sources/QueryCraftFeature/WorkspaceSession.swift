public protocol WorkspaceSession: AnyObject, Sendable {
    func connect() async throws
    func isConnected() async -> Bool
    func fetchDatabases() async throws -> [String]
    func fetchSchemas(in database: String) async throws -> [String]
    func applyQueryContext(_ context: WorkspaceQueryContext) async throws
    func fetchSchemaObjectCatalog() async throws -> [WorkspaceSchemaDatabase]
    func fetchSchemaColumns(
        for objects: [WorkspaceSchemaObjectReference]
    ) async throws -> [WorkspaceSchemaObjectColumns]
    func fetchSchemaChoices() async -> WorkspaceDatabaseSchemaChoices
    func schemaEditingProvider() async -> (any DatabaseSchemaEditingProvider)?
    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject]
    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails
    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex]
    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult
    func fetchDataPage(
        for object: WorkspaceDatabaseObject,
        in database: String,
        offset: Int,
        limit: Int,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async -> Void
    ) async throws -> WorkspaceDatabaseDataFetchResult
    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int
    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String,
        filter: WorkspaceDatabaseDataFilter
    ) async throws -> Int
    func updateDataCell(
        _ update: WorkspaceDatabaseDataCellUpdate
    ) async throws -> Int
    func updateDataCells(
        _ updates: [WorkspaceDatabaseDataCellUpdate]
    ) async throws
    func insertDataRow(
        _ insert: WorkspaceDatabaseDataRowInsert
    ) async throws -> Int
    func insertDataRows(
        _ inserts: [WorkspaceDatabaseDataRowInsert]
    ) async throws
    func deleteDataRow(
        _ delete: WorkspaceDatabaseDataRowDelete
    ) async throws -> Int
    func applyDataChanges(
        _ changes: WorkspaceDatabaseDataChangeSet
    ) async throws
    func applySchemaChanges(
        _ changes: WorkspaceDatabaseSchemaChangeSet
    ) async throws
    func applySchemaExecutionPlan(
        _ plan: WorkspaceDatabaseSchemaExecutionPlan
    ) async throws
    func connectionID() async throws -> Int
    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult
    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult
    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult
    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult
    func cancelQuery(connectionID: Int) async throws
    func close() async
}

public extension WorkspaceSession {
    func fetchSchemas(in database: String) async throws -> [String] { [] }

    func applyQueryContext(_ context: WorkspaceQueryContext) async throws {
        guard context.schemaName == nil else {
            throw WorkspaceSessionError.queryUnavailable
        }
    }

    func schemaEditingProvider() async -> (any DatabaseSchemaEditingProvider)? {
        nil
    }

    func fetchSchemaChoices() async -> WorkspaceDatabaseSchemaChoices {
        .empty
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
        try await fetchDataPage(
            for: object,
            in: database,
            offset: offset,
            limit: limit,
            sort: sort,
            onBatch: onBatch
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String,
        filter: WorkspaceDatabaseDataFilter
    ) async throws -> Int {
        try await fetchDataCount(for: object, in: database)
    }

    func updateDataCell(
        _ update: WorkspaceDatabaseDataCellUpdate
    ) async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func updateDataCells(
        _ updates: [WorkspaceDatabaseDataCellUpdate]
    ) async throws {
        for update in updates {
            try Task.checkCancellation()
            let affectedRows = try await updateDataCell(update)
            switch affectedRows {
            case 1:
                continue
            case 0:
                throw WorkspaceDatabaseDataCellEditError.rowChanged
            default:
                throw WorkspaceDatabaseDataCellEditError
                    .unexpectedAffectedRows(affectedRows)
            }
        }
    }

    func insertDataRow(
        _ insert: WorkspaceDatabaseDataRowInsert
    ) async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func insertDataRows(
        _ inserts: [WorkspaceDatabaseDataRowInsert]
    ) async throws {
        for insert in inserts {
            try Task.checkCancellation()
            let affectedRows = try await insertDataRow(insert)
            guard affectedRows == 1 else {
                throw WorkspaceDatabaseDataRowInsertError
                    .unexpectedAffectedRows(affectedRows)
            }
        }
    }

    func deleteDataRow(
        _ delete: WorkspaceDatabaseDataRowDelete
    ) async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func applyDataChanges(
        _ changes: WorkspaceDatabaseDataChangeSet
    ) async throws {
        for delete in changes.deletes {
            try Task.checkCancellation()
            let affectedRows = try await deleteDataRow(delete)
            guard affectedRows == 1 else {
                if affectedRows == 0 {
                    throw WorkspaceDatabaseDataRowDeleteError.rowChanged
                }
                throw WorkspaceDatabaseDataRowDeleteError
                    .unexpectedAffectedRows(affectedRows)
            }
        }
        try await updateDataCells(changes.updates)
        try await insertDataRows(changes.inserts)
    }

    func applySchemaChanges(
        _ changes: WorkspaceDatabaseSchemaChangeSet
    ) async throws {
        throw WorkspaceSessionError.queryUnavailable
    }

    func applySchemaExecutionPlan(
        _ plan: WorkspaceDatabaseSchemaExecutionPlan
    ) async throws {
        throw WorkspaceSessionError.queryUnavailable
    }

    func isConnected() async -> Bool {
        true
    }

    func fetchSchemaObjectCatalog() async throws -> [WorkspaceSchemaDatabase] {
        []
    }

    func fetchSchemaColumns(
        for objects: [WorkspaceSchemaObjectReference]
    ) async throws -> [WorkspaceSchemaObjectColumns] {
        []
    }

    func connectionID() async throws -> Int {
        throw WorkspaceSessionError.queryUnavailable
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        throw WorkspaceSessionError.queryUnavailable
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        try await executeReadOnlyQuery(
            sql,
            database: database,
            onBatch: onBatch
        )
    }

    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        try await executeReadOnlyQuery(
            sql,
            database: database,
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
        try await executeStatement(
            sql,
            kind: kind,
            database: database,
            onBatch: onBatch
        )
    }

    func cancelQuery(connectionID: Int) async throws {
        throw WorkspaceSessionError.queryUnavailable
    }
}

protocol WorkspaceSessionFactory: Sendable {
    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession
    func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> (any WorkspaceSession)?
}

extension WorkspaceSessionFactory {
    func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> (any WorkspaceSession)? {
        nil
    }
}
