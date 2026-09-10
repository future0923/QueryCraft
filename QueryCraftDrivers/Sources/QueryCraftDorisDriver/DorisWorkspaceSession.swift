import Foundation
import QueryCraftFeature
import QueryCraftMariaDBTransport

actor DorisWorkspaceSession: WorkspaceSession, WorkspaceSessionCapabilityProviding {
    nonisolated let capabilities = WorkspaceSessionCapabilities.dorisReadOnly

    private struct FilterPredicate: Sendable {
        let sql: String
        let bindings: [WorkspaceDatabaseDataCell]
    }

    private let configuration: DorisConnectionConfiguration
    private var client: MariaDBClient?

    init(configuration: DorisConnectionConfiguration) {
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
        var databases: [WorkspaceSchemaDatabase] = []
        for database in try await fetchDatabases() {
            try Task.checkCancellation()
            let objects = try await fetchObjects(in: database).map {
                WorkspaceSchemaObject(name: $0.name, kind: $0.kind, columns: [])
            }
            databases.append(WorkspaceSchemaDatabase(name: database, objects: objects))
        }
        return databases
    }

    func fetchSchemaColumns(
        for objects: [WorkspaceSchemaObjectReference]
    ) async throws -> [WorkspaceSchemaObjectColumns] {
        var output: [WorkspaceSchemaObjectColumns] = []
        output.reserveCapacity(objects.count)
        for reference in objects {
            try Task.checkCancellation()
            let result = try await requireClient().query(
                "SHOW FULL COLUMNS FROM \(qualifiedName(database: reference.databaseName, object: reference.objectName))"
            )
            let columns = result.dictionaryRows.enumerated().compactMap {
                index, row -> WorkspaceSchemaColumn? in
                guard let name = value(in: row, keys: ["Field", "field"]),
                      let type = value(in: row, keys: ["Type", "type"])
                else { return nil }
                return WorkspaceSchemaColumn(
                    name: name,
                    type: type,
                    ordinalPosition: index + 1
                )
            }
            output.append(
                WorkspaceSchemaObjectColumns(reference: reference, columns: columns)
            )
        }
        return output
    }

    func fetchObjects(in database: String) async throws -> [WorkspaceDatabaseObject] {
        let result = try await requireClient().query(
            "SHOW FULL TABLES FROM \(quoteIdentifier(database))"
        )
        try Task.checkCancellation()
        return result.rows.compactMap { row in
            guard let name = row.first ?? nil else { return nil }
            let rawType = row.indices.contains(1) ? row[1]?.uppercased() : nil
            switch rawType {
            case "VIEW":
                return WorkspaceDatabaseObject(name: name, kind: .view)
            case "BASE TABLE", "TABLE", .none:
                return WorkspaceDatabaseObject(name: name, kind: .table)
            default:
                return nil
            }
        }
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        let name = qualifiedName(database: database, object: object.name)
        let columnResult = try await requireClient().query(
            "SHOW FULL COLUMNS FROM \(name)"
        )
        try Task.checkCancellation()
        let columns = columnResult.dictionaryRows.compactMap {
            row -> WorkspaceDatabaseColumn? in
            guard let name = value(in: row, keys: ["Field", "field"]),
                  let type = value(in: row, keys: ["Type", "type"])
            else { return nil }
            return WorkspaceDatabaseColumn(
                name: name,
                type: type,
                collation: value(in: row, keys: ["Collation", "collation"]),
                isNullable: value(in: row, keys: ["Null", "null"]) == "YES",
                key: value(in: row, keys: ["Key", "key"]) ?? "",
                defaultValue: value(in: row, keys: ["Default", "default"]),
                extra: value(in: row, keys: ["Extra", "extra"]) ?? "",
                comment: value(in: row, keys: ["Comment", "comment"]) ?? ""
            )
        }
        let showCreate = object.kind == .view
            ? "SHOW CREATE VIEW \(name)"
            : "SHOW CREATE TABLE \(name)"
        let ddlResult = try await requireClient().query(showCreate)
        guard let ddl = ddlResult.rows.first.flatMap({ row in
            row.indices.contains(1) ? row[1] : nil
        }) else {
            throw WorkspaceSessionError.metadataUnavailable(object: object.name)
        }
        return WorkspaceDatabaseObjectDetails(columns: columns, ddl: ddl)
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        guard object.kind == .table else { return [] }
        do {
            let result = try await requireClient().query(
                "SHOW INDEX FROM \(qualifiedName(database: database, object: object.name))"
            )
            return parseIndexes(result)
        } catch {
            return []
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
        let name = qualifiedName(database: database, object: object.name)
        let predicate = try makeFilterPredicate(filter)
        let orderClause = switch sort {
        case .none: ""
        case let .ascending(columnName):
            " ORDER BY \(quoteIdentifier(columnName)) ASC"
        case let .descending(columnName):
            " ORDER BY \(quoteIdentifier(columnName)) DESC"
        }
        let result = try await requireClient().query(
            "SELECT * FROM \(name)\(predicate.sql)\(orderClause) LIMIT \(limit + 1) OFFSET \(offset)",
            bindings: predicate.bindings
        )
        try Task.checkCancellation()
        let columns = dataColumns(from: result)
        let rows = dataRows(from: result, offset: offset, limit: limit)
        if !columns.isEmpty || !rows.isEmpty {
            await onBatch(WorkspaceDatabaseDataBatch(columns: columns, rows: rows))
        }
        return WorkspaceDatabaseDataFetchResult(
            columns: columns,
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
        let predicate = try makeFilterPredicate(filter)
        let result = try await requireClient().query(
            "SELECT COUNT(*) AS row_count FROM \(qualifiedName(database: database, object: object.name))\(predicate.sql)",
            bindings: predicate.bindings
        )
        guard let rawValue = result.rows.first?.first ?? nil,
              let count = Int(rawValue)
        else {
            throw WorkspaceSessionError.metadataUnavailable(object: object.name)
        }
        return count
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
        try await executeQuery(
            sql,
            database: database,
            maximumRows: maximumRows,
            onBatch: onBatch
        )
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
        if case .transaction = kind {
            throw WorkspaceSessionError.queryUnavailable
        }
        return try await executeQuery(
            sql,
            database: database,
            maximumRows: kind == .read ? maximumRows : nil,
            onBatch: onBatch
        )
    }

    func cancelQuery(connectionID: Int) async throws {
        guard connectionID > 0 else {
            throw WorkspaceSessionError.invalidConnectionID
        }
        let cancellationClient = MariaDBClient(
            configuration: configuration.transportConfiguration
        )
        try await cancellationClient.connect()
        do {
            _ = try await cancellationClient.query("KILL QUERY \(connectionID)")
        } catch {
            await cancellationClient.close()
            throw error
        }
        await cancellationClient.close()
    }

    func close() async {
        let client = self.client
        self.client = nil
        await client?.close()
    }

    private func executeQuery(
        _ sql: String,
        database: String?,
        maximumRows: Int?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        let client = try requireClient()
        if let database, !database.isEmpty {
            _ = try await client.query("USE \(quoteIdentifier(database))")
        }
        let result = try await client.query(sql)
        try Task.checkCancellation()
        let columns = dataColumns(from: result)
        let rows = dataRows(
            from: result,
            offset: 0,
            limit: maximumRows ?? result.rows.count
        )
        if !columns.isEmpty || !rows.isEmpty {
            try await onBatch(WorkspaceDatabaseDataBatch(columns: columns, rows: rows))
        }
        return WorkspaceQueryExecutionResult(
            columns: columns,
            rowCount: rows.isEmpty ? Int(result.affectedRows) : rows.count
        )
    }

    private func dataColumns(
        from result: CDatabaseQueryResult
    ) -> [WorkspaceDatabaseDataColumn] {
        result.columns.enumerated().map {
            WorkspaceDatabaseDataColumn(id: $0.offset, name: $0.element)
        }
    }

    private func dataRows(
        from result: CDatabaseQueryResult,
        offset: Int,
        limit: Int
    ) -> [WorkspaceDatabaseDataRow] {
        result.rows.prefix(limit).enumerated().map { index, row in
            WorkspaceDatabaseDataRow(
                id: offset + index,
                values: row.map {
                    $0.map(WorkspaceDatabaseDataCell.text) ?? .null
                }
            )
        }
    }

    private func parseIndexes(
        _ result: CDatabaseQueryResult
    ) -> [WorkspaceDatabaseIndex] {
        var names: [String] = []
        var columns: [String: [WorkspaceDatabaseIndexColumn]] = [:]
        var properties: [String: (Bool, String, String)] = [:]
        for row in result.dictionaryRows {
            guard let name = value(in: row, keys: ["Key_name", "KeyName"]),
                  let column = value(in: row, keys: ["Column_name", "Column"])
            else { continue }
            let sequence = value(in: row, keys: ["Seq_in_index", "Seq"])
                .flatMap(Int64.init) ?? Int64(columns[name, default: []].count + 1)
            if properties[name] == nil {
                names.append(name)
                properties[name] = (
                    value(in: row, keys: ["Non_unique"]).flatMap(Int.init) == 0,
                    value(in: row, keys: ["Index_type", "IndexType"]) ?? "",
                    value(in: row, keys: ["Comment", "Index_comment"]) ?? ""
                )
            }
            columns[name, default: []].append(
                WorkspaceDatabaseIndexColumn(
                    sequence: sequence,
                    name: column,
                    prefixLength: nil,
                    direction: nil,
                    isExpression: false
                )
            )
        }
        return names.compactMap { name in
            guard let property = properties[name] else { return nil }
            return WorkspaceDatabaseIndex(
                name: name,
                columns: columns[name, default: []],
                isUnique: property.0,
                isPrimary: name.uppercased() == "PRIMARY",
                type: property.1,
                cardinality: nil,
                isVisible: true,
                comment: property.2
            )
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
        for condition in conditions {
            let column = quoteIdentifier(condition.columnName)
            switch condition.operation {
            case .equal:
                predicates.append("(\(column) = ?)")
                bindings.append(.text(condition.value))
            case .notEqual:
                predicates.append("(\(column) <> ?)")
                bindings.append(.text(condition.value))
            case .contains:
                predicates.append("(\(column) LIKE ? ESCAPE 0x5c)")
                bindings.append(.text("%\(escapedLike(condition.value))%"))
            case .startsWith:
                predicates.append("(\(column) LIKE ? ESCAPE 0x5c)")
                bindings.append(.text("\(escapedLike(condition.value))%"))
            case .endsWith:
                predicates.append("(\(column) LIKE ? ESCAPE 0x5c)")
                bindings.append(.text("%\(escapedLike(condition.value))"))
            case .lessThan:
                predicates.append("(\(column) < ?)")
                bindings.append(.text(condition.value))
            case .lessThanOrEqual:
                predicates.append("(\(column) <= ?)")
                bindings.append(.text(condition.value))
            case .greaterThan:
                predicates.append("(\(column) > ?)")
                bindings.append(.text(condition.value))
            case .greaterThanOrEqual:
                predicates.append("(\(column) >= ?)")
                bindings.append(.text(condition.value))
            case .between:
                predicates.append("(\(column) BETWEEN ? AND ?)")
                bindings.append(.text(condition.value))
                bindings.append(.text(condition.secondValue))
            case .isNull:
                predicates.append("(\(column) IS NULL)")
            case .isNotNull:
                predicates.append("(\(column) IS NOT NULL)")
            case .term, .terms, .match, .matchPhrase, .wildcard,
                 .rangeLessThan, .rangeLessThanOrEqual,
                 .rangeGreaterThan, .rangeGreaterThanOrEqual, .exists:
                throw WorkspaceSessionError.invalidDataFilter
            }
        }
        let separator = filter.logic == .matchAll ? " AND " : " OR "
        return FilterPredicate(
            sql: " WHERE " + predicates.joined(separator: separator),
            bindings: bindings
        )
    }

    private func value(
        in row: [String: String?],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = row[key] ?? nil { return value }
        }
        return nil
    }

    private func requireClient() throws -> MariaDBClient {
        guard let client else { throw WorkspaceSessionError.notConnected }
        return client
    }

    private func qualifiedName(database: String, object: String) -> String {
        "\(quoteIdentifier(database)).\(quoteIdentifier(object))"
    }

    private func quoteIdentifier(_ identifier: String) -> String {
        "`\(identifier.replacingOccurrences(of: "`", with: "``"))`"
    }

    private func escapedLike(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
