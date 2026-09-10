import Foundation

actor WorkspaceTableDataExportRowSource: WorkspaceDataExportRowSource {
    private static let pageSize = 5_000

    private let sessionFactory: any WorkspaceSessionFactory
    private let configuration: DatabaseConnectionConfiguration
    private let selection: WorkspaceDatabaseObjectSelection
    private let sort: WorkspaceDatabaseDataSort
    private let filter: WorkspaceDatabaseDataFilter
    private var session: (any WorkspaceSession)?
    private var offset = 0
    private var hasMoreRows = true

    init(
        sessionFactory: any WorkspaceSessionFactory,
        configuration: DatabaseConnectionConfiguration,
        selection: WorkspaceDatabaseObjectSelection,
        sort: WorkspaceDatabaseDataSort,
        filter: WorkspaceDatabaseDataFilter = .empty
    ) {
        self.sessionFactory = sessionFactory
        self.configuration = configuration
        self.selection = selection
        self.sort = sort
        self.filter = filter
    }

    func nextBatch() async throws -> [WorkspaceDatabaseDataRow]? {
        try Task.checkCancellation()
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
        let rows = await collector.rows
        hasMoreRows = result.hasNextPage
        offset += rows.count
        if rows.isEmpty {
            hasMoreRows = false
            return nil
        }
        return rows
    }

    func finish() async {
        hasMoreRows = false
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
