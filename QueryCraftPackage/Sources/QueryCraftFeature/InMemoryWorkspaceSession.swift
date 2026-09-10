import Foundation

actor InMemoryWorkspaceSession: WorkspaceSession {
    private let databases: [String]
    private let schemasByDatabase: [String: [String]]
    private let objectsByDatabase: [String: [WorkspaceDatabaseObject]]
    private let detailsByObject: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseObjectDetails
    ]
    private let indexesByObject: [
        WorkspaceDatabaseObjectSelection: [WorkspaceDatabaseIndex]
    ]
    private let dataByObject: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataPage
    ]
    private var isConnected = false
    private var transactionState = WorkspaceQueryTransactionState.disconnected

    init(
        databases: [String],
        schemasByDatabase: [String: [String]] = [:],
        objectsByDatabase: [String: [WorkspaceDatabaseObject]] = [:],
        detailsByObject: [
            WorkspaceDatabaseObjectSelection: WorkspaceDatabaseObjectDetails
        ] = [:],
        indexesByObject: [
            WorkspaceDatabaseObjectSelection: [WorkspaceDatabaseIndex]
        ] = [:],
        dataByObject: [
            WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataPage
        ] = [:]
    ) {
        self.databases = databases
        self.schemasByDatabase = schemasByDatabase
        self.objectsByDatabase = objectsByDatabase
        self.detailsByObject = detailsByObject
        self.indexesByObject = indexesByObject
        self.dataByObject = dataByObject
    }

    func connect() async throws {
        isConnected = true
        transactionState = .autoCommit
    }

    func isConnected() async -> Bool {
        isConnected
    }

    func fetchDatabases() async throws -> [String] {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        return databases
    }

    func fetchSchemas(in database: String) async throws -> [String] {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        return schemasByDatabase[database, default: []]
    }

    func applyQueryContext(_ context: WorkspaceQueryContext) async throws {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
    }

    func fetchSchemaColumns(
        for objects: [WorkspaceSchemaObjectReference]
    ) async throws -> [WorkspaceSchemaObjectColumns] {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        return objects.map { reference in
            let object = objectsByDatabase[reference.databaseName, default: []]
                .first {
                    $0.name.caseInsensitiveCompare(reference.objectName) == .orderedSame
                }
            let columns: [WorkspaceSchemaColumn] = object.map { object in
                let selection = WorkspaceDatabaseObjectSelection(
                    databaseName: reference.databaseName,
                    objectName: object.name,
                    kind: object.kind
                )
                return detailsByObject[selection]?.columns.enumerated().map {
                    index,
                    column in
                    WorkspaceSchemaColumn(
                        name: column.name,
                        type: column.type,
                        ordinalPosition: index + 1
                    )
                } ?? []
            } ?? []
            return WorkspaceSchemaObjectColumns(
                reference: reference,
                columns: columns
            )
        }
    }

    func fetchSchemaObjectCatalog() async throws -> [WorkspaceSchemaDatabase] {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        return databases.map { databaseName in
            WorkspaceSchemaDatabase(
                name: databaseName,
                objects: objectsByDatabase[databaseName, default: []].map {
                    WorkspaceSchemaObject(
                        name: $0.name,
                        kind: $0.kind,
                        columns: []
                    )
                }
            )
        }
    }

    func fetchObjects(
        in database: String
    ) async throws -> [WorkspaceDatabaseObject] {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        return objectsByDatabase[database, default: []]
    }

    func fetchDetails(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> WorkspaceDatabaseObjectDetails {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: database,
            objectName: object.name,
            kind: object.kind
        )
        guard let details = detailsByObject[selection] else {
            throw WorkspaceSessionError.metadataUnavailable(object: object.name)
        }
        return details
    }

    func fetchIndexes(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> [WorkspaceDatabaseIndex] {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: database,
            objectName: object.name,
            kind: object.kind
        )
        return indexesByObject[selection, default: []]
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
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        guard
            offset >= 0,
            limit > 0,
            filter.isValid
        else {
            throw filter.isValid
                ? WorkspaceSessionError.invalidPageRequest
                : WorkspaceSessionError.invalidDataFilter
        }

        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: database,
            objectName: object.name,
            kind: object.kind
        )
        let source = dataByObject[selection]
        let sourceRows = sortedRows(
            filteredRows(
                source?.rows ?? [],
                columns: source?.columns ?? [],
                filter: filter
            ),
            columns: source?.columns ?? [],
            sort: sort
        )
        let start = min(offset, sourceRows.count)
        let visibleRows = sourceRows
            .dropFirst(start)
            .prefix(limit)
            .enumerated()
            .map { index, row in
                WorkspaceDatabaseDataRow(
                    id: offset + index,
                    values: row.values
                )
            }

        let columns = source?.columns ?? []
        if !visibleRows.isEmpty {
            await onBatch(
                WorkspaceDatabaseDataBatch(
                    columns: columns,
                    rows: Array(visibleRows)
                )
            )
        }

        return WorkspaceDatabaseDataFetchResult(
            columns: source?.columns ?? [],
            hasNextPage: sourceRows.count > offset + visibleRows.count
        )
    }

    private func sortedRows(
        _ rows: [WorkspaceDatabaseDataRow],
        columns: [WorkspaceDatabaseDataColumn],
        sort: WorkspaceDatabaseDataSort
    ) -> [WorkspaceDatabaseDataRow] {
        guard
            let columnName = sort.columnName,
            let columnIndex = columns.firstIndex(where: { $0.name == columnName })
        else {
            return rows
        }

        return rows.sorted { lhs, rhs in
            let comparison = compare(
                lhs.value(at: columnIndex),
                rhs.value(at: columnIndex)
            )
            switch sort {
            case .none:
                return false
            case .ascending:
                return comparison == .orderedAscending
            case .descending:
                return comparison == .orderedDescending
            }
        }
    }

    private func filteredRows(
        _ rows: [WorkspaceDatabaseDataRow],
        columns: [WorkspaceDatabaseDataColumn],
        filter: WorkspaceDatabaseDataFilter
    ) -> [WorkspaceDatabaseDataRow] {
        let conditions = filter.enabledConditions
        guard !conditions.isEmpty else { return rows }

        return rows.filter { row in
            let conditionMatches = conditions.map { condition in
                guard let columnIndex = columns.firstIndex(
                    where: { $0.name == condition.columnName }
                ) else {
                    return false
                }
                return matches(
                    row.value(at: columnIndex),
                    condition: condition
                )
            }
            return switch filter.logic {
            case .matchAll:
                conditionMatches.allSatisfy { $0 }
            case .matchAny:
                conditionMatches.contains(true)
            }
        }
    }

    private func matches(
        _ cell: WorkspaceDatabaseDataCell,
        condition: WorkspaceDatabaseDataFilterCondition
    ) -> Bool {
        switch condition.operation {
        case .isNull:
            return cell == .null
        case .isNotNull:
            return cell != .null
        case .equal, .notEqual, .contains, .startsWith, .endsWith,
             .lessThan, .lessThanOrEqual, .greaterThan,
             .greaterThanOrEqual, .between:
            break
        case .term, .terms, .match, .matchPhrase, .wildcard,
             .rangeLessThan, .rangeLessThanOrEqual,
             .rangeGreaterThan, .rangeGreaterThanOrEqual, .exists:
            return false
        }

        guard case let .text(value) = cell else { return false }
        let comparison: ComparisonResult
        if
            condition.columnKind == .number,
            let lhs = Decimal(
                string: value,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            let rhs = Decimal(
                string: condition.value,
                locale: Locale(identifier: "en_US_POSIX")
            )
        {
            comparison = lhs == rhs
                ? .orderedSame
                : (lhs < rhs ? .orderedAscending : .orderedDescending)
        } else {
            comparison = value.compare(condition.value)
        }

        switch condition.operation {
        case .equal:
            return comparison == .orderedSame
        case .notEqual:
            return comparison != .orderedSame
        case .contains:
            return value.contains(condition.value)
        case .startsWith:
            return value.hasPrefix(condition.value)
        case .endsWith:
            return value.hasSuffix(condition.value)
        case .lessThan:
            return comparison == .orderedAscending
        case .lessThanOrEqual:
            return comparison != .orderedDescending
        case .greaterThan:
            return comparison == .orderedDescending
        case .greaterThanOrEqual:
            return comparison != .orderedAscending
        case .between:
            return isBetween(value, condition: condition)
        case .isNull, .isNotNull:
            return false
        case .term, .terms, .match, .matchPhrase, .wildcard,
             .rangeLessThan, .rangeLessThanOrEqual,
             .rangeGreaterThan, .rangeGreaterThanOrEqual, .exists:
            return false
        }
    }

    private func isBetween(
        _ value: String,
        condition: WorkspaceDatabaseDataFilterCondition
    ) -> Bool {
        if
            condition.columnKind == .number,
            let candidate = Decimal(
                string: value,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            let lower = Decimal(
                string: condition.value,
                locale: Locale(identifier: "en_US_POSIX")
            ),
            let upper = Decimal(
                string: condition.secondValue,
                locale: Locale(identifier: "en_US_POSIX")
            )
        {
            return candidate >= lower && candidate <= upper
        }
        return value >= condition.value && value <= condition.secondValue
    }

    private func compare(
        _ lhs: WorkspaceDatabaseDataCell,
        _ rhs: WorkspaceDatabaseDataCell
    ) -> ComparisonResult {
        switch (lhs, rhs) {
        case (.null, .null):
            .orderedSame
        case (.null, _):
            .orderedAscending
        case (_, .null):
            .orderedDescending
        case let (.text(lhs), .text(rhs)):
            lhs.compare(rhs)
        case let (.binary(lhsCount, _), .binary(rhsCount, _)):
            lhsCount == rhsCount
                ? .orderedSame
                : (lhsCount < rhsCount ? .orderedAscending : .orderedDescending)
        case (.text, .binary):
            .orderedAscending
        case (.binary, .text):
            .orderedDescending
        }
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String
    ) async throws -> Int {
        try await fetchDataCount(
            for: object,
            in: database,
            filter: .empty
        )
    }

    func fetchDataCount(
        for object: WorkspaceDatabaseObject,
        in database: String,
        filter: WorkspaceDatabaseDataFilter
    ) async throws -> Int {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        guard filter.isValid else {
            throw WorkspaceSessionError.invalidDataFilter
        }
        let selection = WorkspaceDatabaseObjectSelection(
            databaseName: database,
            objectName: object.name,
            kind: object.kind
        )
        let source = dataByObject[selection]
        return filteredRows(
            source?.rows ?? [],
            columns: source?.columns ?? [],
            filter: filter
        ).count
    }

    func connectionID() async throws -> Int {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        return 1
    }

    func executeReadOnlyQuery(
        _ sql: String,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        let columns = [WorkspaceDatabaseDataColumn(id: 0, name: "result")]
        let rows = [
            WorkspaceDatabaseDataRow(id: 0, values: [.text("1")])
        ]
        try await onBatch(
            WorkspaceDatabaseDataBatch(columns: columns, rows: rows)
        )
        return WorkspaceQueryExecutionResult(columns: columns, rowCount: 1)
    }

    func executeStatement(
        _ sql: String,
        kind: SQLStatementKind,
        database: String?,
        onBatch: @escaping @Sendable (WorkspaceDatabaseDataBatch) async throws -> Void
    ) async throws -> WorkspaceQueryExecutionResult {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
        transactionState = try transactionState.afterSuccessfulStatement(kind)
        guard kind == .read else {
            return WorkspaceQueryExecutionResult(
                columns: [],
                rowCount: 0,
                transactionState: transactionState
            )
        }
        let result = try await executeReadOnlyQuery(
            sql,
            database: database,
            onBatch: onBatch
        )
        return WorkspaceQueryExecutionResult(
            columns: result.columns,
            rowCount: result.rowCount,
            transactionState: transactionState
        )
    }

    func cancelQuery(connectionID: Int) async throws {
        guard isConnected else {
            throw WorkspaceSessionError.notConnected
        }
    }

    func close() async {
        isConnected = false
        transactionState = .disconnected
    }
}

struct InMemoryWorkspaceSessionFactory: WorkspaceSessionFactory {
    let databases: [String]
    var schemasByDatabase: [String: [String]] = [:]
    var objectsByDatabase: [String: [WorkspaceDatabaseObject]] = [:]
    var detailsByObject: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseObjectDetails
    ] = [:]
    var indexesByObject: [
        WorkspaceDatabaseObjectSelection: [WorkspaceDatabaseIndex]
    ] = [:]
    var dataByObject: [
        WorkspaceDatabaseObjectSelection: WorkspaceDatabaseDataPage
    ] = [:]

    func makeSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> any WorkspaceSession {
        InMemoryWorkspaceSession(
            databases: databases,
            schemasByDatabase: schemasByDatabase,
            objectsByDatabase: objectsByDatabase,
            detailsByObject: detailsByObject,
            indexesByObject: indexesByObject,
            dataByObject: dataByObject
        )
    }

    func makeSchemaCatalogSession(
        configuration: DatabaseConnectionConfiguration
    ) async -> (any WorkspaceSession)? {
        await makeSession(configuration: configuration)
    }
}
