import Foundation

/// Desktop session ownership stays here; batch progression is shared with mobile.
struct WorkspaceTableDataExportRowSource: WorkspaceDataExportRowSource {
    private let session: WorkspaceTableDataExportSession
    private let source: WorkspacePagedDataExportRowSource

    init(
        sessionFactory: any WorkspaceSessionFactory,
        configuration: DatabaseConnectionConfiguration,
        selection: WorkspaceDatabaseObjectSelection,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter = .empty,
        requiresCompleteValues: Bool = false
    ) {
        let session = WorkspaceTableDataExportSession(sessionFactory: sessionFactory,
            configuration: configuration, selection: selection, sort: sort, filter: filter)
        self.session = session
        source = WorkspacePagedDataExportRowSource(pageSize: 5_000,
            loadPage: { offset, limit in try await session.page(offset: offset, limit: limit) },
            validateRows: { rows, columns in
                if requiresCompleteValues {
                    try Self.validateCompleteValues(rows, columns: columns, databaseType: configuration.databaseType)
                }
            }, onFinish: { await session.close() })
    }

    func prepareColumns() async throws -> [WorkspaceDatabaseDataColumn] { try await source.prepareColumns() }
    func nextBatch() async throws -> [WorkspaceDatabaseDataRow]? { try await source.nextBatch() }
    func finish() async { await source.finish() }
    func sqlColumns() async throws -> [WorkspaceDatabaseColumn] { try await session.sqlColumns() }

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

}

private actor WorkspaceTableDataExportSession {
    private let sessionFactory: any WorkspaceSessionFactory
    private let configuration: DatabaseConnectionConfiguration
    private let selection: WorkspaceDatabaseObjectSelection
    private let sort: WorkspaceDatabaseDataSort
    private let filter: WorkspaceDatabaseDataFilter
    private var session: (any WorkspaceSession)?

    init(sessionFactory: any WorkspaceSessionFactory, configuration: DatabaseConnectionConfiguration,
         selection: WorkspaceDatabaseObjectSelection, sort: WorkspaceDatabaseDataSort,
         filter: WorkspaceDatabaseDataFilter) {
        self.sessionFactory = sessionFactory; self.configuration = configuration
        self.selection = selection; self.sort = sort; self.filter = filter
    }

    func page(offset: Int, limit: Int) async throws -> WorkspacePagedDataExportRowSource.Page {
        let session = try await connectedSession()
        let collector = WorkspaceDataExportBatchCollector()
        let result = try await session.fetchDataPage(for: selection.object, in: selection.databaseName,
            offset: offset, limit: limit, sort: sort, filter: filter) { batch in
                await collector.append(batch.rows)
            }
        return await .init(columns: result.columns, rows: collector.rows, hasNextPage: result.hasNextPage)
    }

    func sqlColumns() async throws -> [WorkspaceDatabaseColumn] {
        let session = try await connectedSession()
        return try await session.fetchDetails(for: selection.object, in: selection.databaseName).columns
    }

    func close() async {
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
    func append(_ newRows: [WorkspaceDatabaseDataRow]) { rows.append(contentsOf: newRows) }
}
