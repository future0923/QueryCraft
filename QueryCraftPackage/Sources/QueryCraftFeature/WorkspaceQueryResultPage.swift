import Foundation

struct WorkspaceQueryResultPage: Equatable, Sendable {
    let revision = UUID()
    let columns: [WorkspaceDatabaseDataColumn]
    let store: WorkspaceQueryResultStore
    let rowCount: Int

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
