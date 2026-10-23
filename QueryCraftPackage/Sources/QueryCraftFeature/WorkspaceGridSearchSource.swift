import Foundation

enum WorkspaceGridSearchSource: WorkspaceGridSearchDataSource {
    case queryResult(WorkspaceQueryResultPage)
    case tablePage(WorkspaceDatabaseDataPage)
    case redisCollection(WorkspaceGridSearchCollectionSource)

    var revision: UUID {
        switch self {
        case let .queryResult(page):
            page.revision
        case let .tablePage(page):
            page.revision
        case let .redisCollection(source):
            source.revision
        }
    }

    var columns: [WorkspaceDatabaseDataColumn] {
        switch self {
        case let .queryResult(page):
            page.columns
        case let .tablePage(page):
            page.columns
        case let .redisCollection(source):
            source.columns
        }
    }

    var rowCount: Int {
        switch self {
        case let .queryResult(page):
            page.rowCount
        case let .tablePage(page):
            page.rowCount
        case let .redisCollection(source):
            source.rows.count
        }
    }

    func row(at index: Int) -> WorkspaceDatabaseDataRow? {
        return switch self {
        case let .queryResult(page):
            page.row(at: index)
        case let .tablePage(page):
            page.row(at: index)
        case let .redisCollection(source):
            source.rows.indices.contains(index) ? source.rows[index] : nil
        }
    }
}

struct WorkspaceGridSearchCollectionSource: Sendable {
    let revision: UUID
    let columns: [WorkspaceDatabaseDataColumn]
    let rows: [WorkspaceDatabaseDataRow]
}

// Preserve inferred .tablePage/.queryResult/.redisCollection call sites on Mac.
extension WorkspaceGridSearchWorker {
    func search(source: WorkspaceGridSearchSource, request: WorkspaceGridSearchRequest) async throws -> WorkspaceGridSearchResult {
        try await search(source: source as any WorkspaceGridSearchDataSource, request: request)
    }
}

extension WorkspaceGridSearchController {
    func update(source: WorkspaceGridSearchSource) {
        update(source: source as any WorkspaceGridSearchDataSource)
    }
}
