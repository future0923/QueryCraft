import Foundation
import QueryCraftFeature
import QueryCraftMariaDBTransport

actor MySQLWorkspaceSession: WorkspaceSession {
    private struct FilterPredicate: Sendable {
        let sql: String
        let bindings: [WorkspaceDatabaseDataCell]
    }

    private let configuration: MySQLConnectionConfiguration
    private var client: MariaDBClient?
    private var transactionState = WorkspaceQueryTransactionState.disconnected
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
        transactionState = .autoCommit
    }

    func isConnected() async -> Bool {
        await client?.isConnected() == true
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
        let databaseNames = try await fetchDatabases()
        try Task.checkCancellation()
        let result = try await requireClient().query(
            """
            SELECT
                TABLE_SCHEMA AS database_name,
                TABLE_NAME AS object_name,
                TABLE_TYPE AS object_type
            FROM information_schema.TABLES
            ORDER BY TABLE_SCHEMA, TABLE_NAME
            """
        )
        try Task.checkCancellation()

        var objectsByDatabase: [String: [WorkspaceSchemaObject]] = [:]
        for row in result.dictionaryRows {
            guard
                let databaseName = row["database_name"] ?? nil,
                let objectName = row["object_name"] ?? nil,
                let rawObjectType = row["object_type"] ?? nil
            else { continue }

            let kind: WorkspaceDatabaseObjectKind
            switch rawObjectType {
            case "BASE TABLE": kind = .table
            case "VIEW": kind = .view
            default: continue
            }
            objectsByDatabase[databaseName, default: []].append(
                WorkspaceSchemaObject(name: objectName, kind: kind, columns: [])
            )
        }

        return databaseNames.map { databaseName in
            WorkspaceSchemaDatabase(
                name: databaseName,
                objects: objectsByDatabase[databaseName, default: []]
            )
        }
    }

    func fetchSchemaColumns(
        for objects: [WorkspaceSchemaObjectReference]
    ) async throws -> [WorkspaceSchemaObjectColumns] {
        let objects = Array(Set(objects))
        guard !objects.isEmpty else { return [] }
        let objectPredicates = objects.map { reference in
            "(c.TABLE_SCHEMA = \(hexStringLiteral(reference.databaseName)) "
                + "AND c.TABLE_NAME = \(hexStringLiteral(reference.objectName)))"
        }.joined(separator: " OR ")
        let result = try await requireClient().query(
            """
            SELECT
                c.TABLE_SCHEMA AS database_name,
                c.TABLE_NAME AS object_name,
                c.COLUMN_NAME AS column_name,
                c.COLUMN_TYPE AS column_type,
                c.ORDINAL_POSITION AS ordinal_position
            FROM information_schema.COLUMNS AS c
            WHERE \(objectPredicates)
            ORDER BY
                c.TABLE_SCHEMA,
                c.TABLE_NAME,
                c.ORDINAL_POSITION
            """
        )
        try Task.checkCancellation()

        var columnsByObject: [WorkspaceSchemaObjectReference: [WorkspaceSchemaColumn]] = [:]
        for row in result.dictionaryRows {
            guard
                let databaseName = row["database_name"] ?? nil,
                let objectName = row["object_name"] ?? nil,
                let columnName = row["column_name"] ?? nil,
                let columnType = row["column_type"] ?? nil,
                let ordinalValue = row["ordinal_position"] ?? nil,
                let ordinalPosition = Int(ordinalValue)
            else { continue }
            let key = WorkspaceSchemaObjectReference(
                databaseName: databaseName,
                objectName: objectName
            )
            columnsByObject[key, default: []].append(
                WorkspaceSchemaColumn(
                    name: columnName,
                    type: columnType,
                    ordinalPosition: ordinalPosition
                )
            )
        }

        return objects.map { reference in
            WorkspaceSchemaObjectColumns(
                reference: reference,
                columns: columnsByObject[reference, default: []]
            )
        }
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

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        let qualifiedName = "\(quoteIdentifier(database)).\(quoteIdentifier(object.name))"
        let columnResult = try await requireClient().query(
            """
            SELECT
                COLUMN_NAME AS column_name,
                COLUMN_TYPE AS column_type,
                COLLATION_NAME AS collation_name,
                IS_NULLABLE AS is_nullable,
                COLUMN_KEY AS column_key,
                COLUMN_DEFAULT AS column_default,
                EXTRA AS extra,
                COLUMN_COMMENT AS column_comment
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(hexStringLiteral(database))
                AND TABLE_NAME = \(hexStringLiteral(object.name))
            ORDER BY ORDINAL_POSITION
            """
        )
        try Task.checkCancellation()

        let columns = columnResult.dictionaryRows.compactMap {
            row -> WorkspaceDatabaseColumn? in
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
                generationExpression: ""
            )
        }

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

        var names: [String] = []
        var columnsByName: [String: [WorkspaceDatabaseIndexColumn]] = [:]
        var propertiesByName: [
            String: (
                isUnique: Bool,
                type: String,
                cardinality: Int64?,
                cardinalityPosition: Int64,
                isVisible: Bool,
                comment: String
            )
        ] = [:]

        for row in result.dictionaryRows {
            guard
                let name = row["Key_name"] ?? nil,
                let positionText = row["Seq_in_index"] ?? nil,
                let position = Int64(positionText)
            else { continue }

            let storedColumnName = row["Column_name"] ?? nil
            let expression = row["Expression"] ?? nil
            let columnName = storedColumnName ?? expression ?? ""
            guard !columnName.isEmpty else { continue }

            if propertiesByName[name] == nil {
                names.append(name)
                propertiesByName[name] = (
                    isUnique: (row["Non_unique"] ?? nil).flatMap(Int64.init) == 0,
                    type: (row["Index_type"] ?? nil) ?? "",
                    cardinality: (row["Cardinality"] ?? nil).flatMap(Int64.init),
                    cardinalityPosition: position,
                    isVisible: (row["Visible"] ?? nil) != "NO",
                    comment: (row["Index_comment"] ?? nil) ?? ""
                )
            } else if
                let properties = propertiesByName[name],
                position >= properties.cardinalityPosition
            {
                propertiesByName[name] = (
                    properties.isUnique,
                    properties.type,
                    (row["Cardinality"] ?? nil).flatMap(Int64.init),
                    position,
                    properties.isVisible,
                    properties.comment
                )
            }
            columnsByName[name, default: []].append(
                WorkspaceDatabaseIndexColumn(
                    sequence: position,
                    name: columnName,
                    prefixLength: (row["Sub_part"] ?? nil).flatMap(Int64.init),
                    direction: row["Collation"] ?? nil,
                    isExpression: storedColumnName == nil && expression != nil
                )
            )
        }

        return names.compactMap { name in
            guard let properties = propertiesByName[name] else { return nil }
            return WorkspaceDatabaseIndex(
                name: name,
                columns: columnsByName[name, default: []]
                    .sorted { $0.sequence < $1.sequence },
                isUnique: properties.isUnique,
                type: properties.type,
                cardinality: properties.cardinality,
                isVisible: properties.isVisible,
                comment: properties.comment
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

        let columns = result.columns.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
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
        _ = try await client.query("START TRANSACTION")
        do {
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
                let affectedRows = try await insertDataRow(insert)
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
        let result = try await executeQuery(
            sql,
            maximumRows: kind == .read ? maximumRows : nil,
            onBatch: onBatch
        )
        transactionState = try transactionState.afterSuccessfulStatement(kind)
        return result.withTransactionState(transactionState)
    }

    func cancelQuery(connectionID: Int) async throws {
        guard connectionID > 0 else {
            throw WorkspaceSessionError.invalidConnectionID
        }
        _ = try await requireClient().query("KILL QUERY \(connectionID)")
    }

    func close() async {
        transactionState = .disconnected
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
            let result = try await client.query(sql)
            try Task.checkCancellation()
            if maximumRows != nil {
                _ = try await client.query("SET SESSION SQL_SELECT_LIMIT = DEFAULT")
            }
            let columns = result.columns.enumerated().map { index, name in
                let origin = (result.columnOrigins.indices.contains(index)
                    ? result.columnOrigins[index]
                    : nil).map {
                    WorkspaceDatabaseDataColumn.Origin(
                        databaseName: $0.databaseName,
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
                rowCount: rows.isEmpty ? Int(result.affectedRows) : rows.count
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
            """
            SELECT
                ENGINE AS table_engine,
                TABLE_COLLATION AS table_collation,
                ROW_FORMAT AS row_format,
                TABLE_ROWS AS estimated_row_count,
                AUTO_INCREMENT AS next_auto_increment,
                CREATE_OPTIONS AS create_options,
                CAST(CREATE_TIME AS CHAR) AS creation_time,
                CAST(UPDATE_TIME AS CHAR) AS update_time,
                DATA_LENGTH AS data_size,
                INDEX_LENGTH AS index_size,
                TABLE_COMMENT AS table_comment
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(hexStringLiteral(database))
                AND TABLE_NAME = \(hexStringLiteral(objectName))
            LIMIT 1
            """
        )
        guard let row = tableResult.dictionaryRows.first else { return nil }
        let createOptions = (row["create_options"] ?? nil) ?? ""
        return WorkspaceDatabaseTableInformation(
            dataSize: (row["data_size"] ?? nil).flatMap(Int64.init),
            indexSize: (row["index_size"] ?? nil).flatMap(Int64.init),
            comment: (row["table_comment"] ?? nil) ?? "",
            engine: row["table_engine"] ?? nil,
            collation: row["table_collation"] ?? nil,
            rowFormat: row["row_format"] ?? nil,
            estimatedRowCount: (row["estimated_row_count"] ?? nil)
                .flatMap(Int64.init),
            nextAutoIncrement: (row["next_auto_increment"] ?? nil)
                .flatMap(Int64.init),
            averageRowLength: WorkspaceDatabaseTableInformation
                .numericCreateOption("avg_row_length", in: createOptions),
            minimumRows: WorkspaceDatabaseTableInformation
                .numericCreateOption("min_rows", in: createOptions),
            maximumRows: WorkspaceDatabaseTableInformation
                .numericCreateOption("max_rows", in: createOptions),
            keyBlockSize: WorkspaceDatabaseTableInformation
                .numericCreateOption("key_block_size", in: createOptions),
            creationTime: row["creation_time"] ?? nil,
            updateTime: row["update_time"] ?? nil
        )
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

    private func makeFilterPredicate(
        _ filter: WorkspaceDatabaseDataFilter
    ) throws -> FilterPredicate {
        let conditions = filter.enabledConditions
        guard !conditions.isEmpty else {
            return FilterPredicate(sql: "", bindings: [])
        }
        guard filter.isValid else {
            throw WorkspaceSessionError.invalidDataFilter
        }

        var predicates: [String] = []
        var bindings: [WorkspaceDatabaseDataCell] = []
        predicates.reserveCapacity(conditions.count)

        for condition in conditions {
            let column = quoteIdentifier(condition.columnName)
            let predicate: String
            switch condition.operation {
            case .equal:
                predicate = "\(column) = ?"
                bindings.append(.text(condition.value))
            case .notEqual:
                predicate = "\(column) <> ?"
                bindings.append(.text(condition.value))
            case .contains:
                predicate = "\(column) LIKE ? ESCAPE 0x5c"
                bindings.append(.text("%\(escapedLike(condition.value))%"))
            case .startsWith:
                predicate = "\(column) LIKE ? ESCAPE 0x5c"
                bindings.append(.text("\(escapedLike(condition.value))%"))
            case .endsWith:
                predicate = "\(column) LIKE ? ESCAPE 0x5c"
                bindings.append(.text("%\(escapedLike(condition.value))"))
            case .lessThan:
                predicate = "\(column) < ?"
                bindings.append(.text(condition.value))
            case .lessThanOrEqual:
                predicate = "\(column) <= ?"
                bindings.append(.text(condition.value))
            case .greaterThan:
                predicate = "\(column) > ?"
                bindings.append(.text(condition.value))
            case .greaterThanOrEqual:
                predicate = "\(column) >= ?"
                bindings.append(.text(condition.value))
            case .between:
                predicate = "\(column) BETWEEN ? AND ?"
                bindings.append(.text(condition.value))
                bindings.append(.text(condition.secondValue))
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
        return FilterPredicate(
            sql: " WHERE " + predicates.joined(separator: separator),
            bindings: bindings
        )
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

    private func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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
