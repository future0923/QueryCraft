import Foundation

struct WorkspaceQueryResultPage: Equatable, Sendable {
    let revision = UUID()
    let columns: [WorkspaceDatabaseDataColumn]
    let store: WorkspaceQueryResultStore
    private let commandRowCount: Int
    var rowCount: Int { columns.isEmpty ? commandRowCount : store.rowCount }

    init(
        columns: [WorkspaceDatabaseDataColumn],
        store: WorkspaceQueryResultStore,
        rowCount: Int
    ) {
        // Row results follow the store so committed deletions remain visible.
        // Commands have no stored rows; retain the driver's affected-row count.
        commandRowCount = rowCount
        self.columns = columns
        self.store = store
    }

    func row(at index: Int) -> WorkspaceDatabaseDataRow? {
        guard index >= 0, index < rowCount else { return nil }
        return store.row(at: index)
    }

    func cachedRow(at index: Int) -> WorkspaceDatabaseDataRow? {
        guard index >= 0, index < rowCount else { return nil }
        return store.cachedRow(at: index)
    }

    func loadRows(containing index: Int) async throws -> Range<Int>? {
        guard index >= 0, index < rowCount else { return nil }
        return try await store.loadPage(containing: index)
    }

    static func == (
        lhs: WorkspaceQueryResultPage,
        rhs: WorkspaceQueryResultPage
    ) -> Bool {
        lhs.columns == rhs.columns
            && lhs.rowCount == rhs.rowCount
            && lhs.store === rhs.store
    }
}
