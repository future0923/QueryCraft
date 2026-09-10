import Foundation

struct WorkspaceDatabaseDataPage: Equatable, Sendable {
    static let defaultLimit = 200

    let revision = UUID()
    let columns: [WorkspaceDatabaseDataColumn]
    let rowStore: WorkspaceDatabaseDataRowStore
    let rowCount: Int
    let offset: Int
    let limit: Int
    let hasNextPage: Bool
    let sort: WorkspaceDatabaseDataSort
    let filter: WorkspaceDatabaseDataFilter

    init(
        columns: [WorkspaceDatabaseDataColumn],
        rows: [WorkspaceDatabaseDataRow],
        offset: Int,
        limit: Int,
        hasNextPage: Bool,
        sort: WorkspaceDatabaseDataSort = .none,
        filter: WorkspaceDatabaseDataFilter = .empty
    ) {
        self.columns = columns
        rowStore = WorkspaceDatabaseDataRowStore(rows: rows)
        rowCount = rows.count
        self.offset = offset
        self.limit = limit
        self.hasNextPage = hasNextPage
        self.sort = sort
        self.filter = filter
    }

    init(
        columns: [WorkspaceDatabaseDataColumn],
        rowStore: WorkspaceDatabaseDataRowStore,
        offset: Int,
        limit: Int,
        hasNextPage: Bool,
        sort: WorkspaceDatabaseDataSort = .none,
        filter: WorkspaceDatabaseDataFilter = .empty
    ) {
        self.columns = columns
        self.rowStore = rowStore
        rowCount = rowStore.count
        self.offset = offset
        self.limit = limit
        self.hasNextPage = hasNextPage
        self.sort = sort
        self.filter = filter
    }

    var rows: [WorkspaceDatabaseDataRow] {
        Array(rowStore.rows.prefix(rowCount))
    }

    func row(at index: Int) -> WorkspaceDatabaseDataRow? {
        guard index >= 0, index < rowCount else { return nil }
        return rowStore.row(at: index)
    }

    var pageNumber: Int {
        (offset / limit) + 1
    }

    var firstRowNumber: Int? {
        rowCount == 0 ? nil : offset + 1
    }

    var lastRowNumber: Int? {
        rowCount == 0 ? nil : offset + rowCount
    }

    static func == (
        lhs: WorkspaceDatabaseDataPage,
        rhs: WorkspaceDatabaseDataPage
    ) -> Bool {
        guard
            lhs.columns == rhs.columns,
            lhs.rowCount == rhs.rowCount,
            lhs.offset == rhs.offset,
            lhs.limit == rhs.limit,
            lhs.hasNextPage == rhs.hasNextPage,
            lhs.sort == rhs.sort,
            lhs.filter == rhs.filter
        else {
            return false
        }

        if lhs.rowStore === rhs.rowStore {
            return true
        }
        return lhs.rows == rhs.rows
    }
}
