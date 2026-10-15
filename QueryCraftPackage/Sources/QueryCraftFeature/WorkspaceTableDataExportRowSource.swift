import Foundation

actor WorkspaceTableDataExportRowSource: WorkspaceDataExportRowSource {
    private static let pageSize = 5_000

    private let sessionFactory: any WorkspaceSessionFactory
    private let configuration: DatabaseConnectionConfiguration
    private let selection: WorkspaceDatabaseObjectSelection
    private let sort: WorkspaceDatabaseDataSort
    private let filter: WorkspaceDatabaseDataFilter
    private let requiresCompleteValues: Bool
    private var session: (any WorkspaceSession)?
    private var preparedRows: [WorkspaceDatabaseDataRow]?
    private var columns: [WorkspaceDatabaseDataColumn] = []
    private var offset = 0
    private var hasMoreRows = true

    init(
        sessionFactory: any WorkspaceSessionFactory,
        configuration: DatabaseConnectionConfiguration,
        selection: WorkspaceDatabaseObjectSelection,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter = .empty,
        requiresCompleteValues: Bool = false
    ) {
        self.sessionFactory = sessionFactory
        self.configuration = configuration
        self.selection = selection
        self.sort = sort
        self.filter = filter
        self.requiresCompleteValues = requiresCompleteValues
    }

    func prepareColumns() async throws -> [WorkspaceDatabaseDataColumn] {
        preparedRows = try await nextBatch()
        return columns
    }

    func sqlColumns() async throws -> [WorkspaceDatabaseColumn] {
        let session = try await connectedSession()
        return try await session.fetchDetails(for: selection.object, in: selection.databaseName).columns
    }

    func nextBatch() async throws -> [WorkspaceDatabaseDataRow]? {
        try Task.checkCancellation()
        if let preparedRows {
            self.preparedRows = nil
            return preparedRows
        }
        guard hasMoreRows else { return nil }

        let session = try await connectedSession()
        let collector = WorkspaceDataExportBatchCollector()
        let result = try await session.fetchDataPage(
            for: selection.object,
            in: selection.databaseName,
            offset: offset,
            limit: Self.pageSize,
            sort: sort,
            filter: filter
        ) { batch in
            await collector.append(batch.rows)
        }
        try Task.checkCancellation()
        if !columns.isEmpty && columns != result.columns {
            throw WorkspaceDataExportError.changedColumns
        }
        columns = result.columns
        let rows = await collector.rows
        if requiresCompleteValues {
            try Self.validateCompleteValues(rows, columns: columns, databaseType: configuration.databaseType)
        }
        hasMoreRows = result.hasNextPage
        offset += rows.count
        if rows.isEmpty {
            hasMoreRows = false
            return nil
        }
        return rows
    }

    static func validateCompleteValues(
        _ rows: [WorkspaceDatabaseDataRow],
        columns: [WorkspaceDatabaseDataColumn],
        databaseType: DatabaseType
    ) throws {
        // MariaDB transport decodes binary bytes as text; original bytes cannot be recovered
        // reliably. PostgreSQL bytea arrives as its lossless textual representation instead.
        let binaryTypes = ["binary", "varbinary", "tinyblob", "blob", "mediumblob", "longblob", "bit", "geometry"]
        for row in rows {
            for (index, column) in columns.enumerated() {
                let value = row.value(at: index)
                guard value != .null else { continue }
                if case .binary = value { throw WorkspaceDataExportError.unavailableColumn(column.name) }
                if databaseType != .postgresql,
                   let type = column.type?.lowercased().split(separator: "(").first.map(String.init),
                   binaryTypes.contains(type) {
                    throw WorkspaceDataExportError.unavailableColumn(column.name)
                }
            }
        }
    }

    func finish() async {
        hasMoreRows = false
        preparedRows = nil
        guard let session else { return }
        self.session = nil
        await session.close()
    }

    private func connectedSession() async throws -> any WorkspaceSession {
        if let session {
            return session
        }
        let newSession = await sessionFactory.makeSession(
            configuration: configuration
        )
        do {
            try await newSession.connect()
            if configuration.databaseType == .postgresql {
                _ = try await newSession.fetchObjects(in: selection.databaseName)
            }
            try Task.checkCancellation()
            session = newSession
            return newSession
        } catch {
            await newSession.close()
            throw error
        }
    }
}

private actor WorkspaceDataExportBatchCollector {
    private(set) var rows: [WorkspaceDatabaseDataRow] = []

    func append(_ newRows: [WorkspaceDatabaseDataRow]) {
        rows.append(contentsOf: newRows)
    }
}
