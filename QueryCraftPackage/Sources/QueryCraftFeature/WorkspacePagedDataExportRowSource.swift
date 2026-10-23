import Foundation
#if os(iOS)
import QueryCraftMobileCore
#endif

/// Same paging/lifetime rules for desktop sessions and bounded mobile readers.
/// The writer prefetches at most one batch; this source never retains all rows.
actor WorkspacePagedDataExportRowSource: WorkspaceDataExportRowSource {
    struct Page: Sendable {
        let columns: [WorkspaceDatabaseDataColumn]
        let rows: [WorkspaceDatabaseDataRow]
        let hasNextPage: Bool
    }

    private let pageSize: Int
    private let loadPage: @Sendable (Int, Int) async throws -> Page
    private let validateRows: @Sendable ([WorkspaceDatabaseDataRow], [WorkspaceDatabaseDataColumn]) throws -> Void
    private let onFinish: @Sendable () async -> Void
    private var columns: [WorkspaceDatabaseDataColumn]?
    private var preparedRows: [WorkspaceDatabaseDataRow]?
    private var offset = 0
    private var hasMoreRows = true
    private var finished = false

    init(pageSize: Int, expectedColumns: [WorkspaceDatabaseDataColumn]? = nil,
         loadPage: @escaping @Sendable (Int, Int) async throws -> Page,
         validateRows: @escaping @Sendable ([WorkspaceDatabaseDataRow], [WorkspaceDatabaseDataColumn]) throws -> Void = { _, _ in },
         onFinish: @escaping @Sendable () async -> Void = {}) {
        self.pageSize = max(1, pageSize); columns = expectedColumns
        self.loadPage = loadPage; self.validateRows = validateRows; self.onFinish = onFinish
    }

    func prepareColumns() async throws -> [WorkspaceDatabaseDataColumn] {
        preparedRows = try await nextBatch()
        return columns ?? []
    }

    func nextBatch() async throws -> [WorkspaceDatabaseDataRow]? {
        try Task.checkCancellation()
        guard !finished else { return nil }
        if let preparedRows { self.preparedRows = nil; return preparedRows }
        guard hasMoreRows else { return nil }
        let page = try await loadPage(offset, pageSize)
        try Task.checkCancellation()
        guard !finished else { throw CancellationError() }
        if let columns, columns != page.columns { throw WorkspaceDataExportError.changedColumns }
        columns = page.columns
        try validateRows(page.rows, page.columns)
        hasMoreRows = page.hasNextPage
        offset += page.rows.count
        guard !page.rows.isEmpty else { hasMoreRows = false; return nil }
        return page.rows
    }

    func finish() async {
        guard !finished else { return }
        finished = true; hasMoreRows = false; preparedRows = nil
        await onFinish()
    }
}
