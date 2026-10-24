import Foundation
import QueryCraftMobileCore

private actor MobileElasticsearchExportSession {
    let makeSession: @Sendable () throws -> any MobileElasticsearchServing
    let object: WorkspaceDatabaseObject
    let sort: WorkspaceDatabaseDataSort
    let filter: WorkspaceDatabaseDataFilter
    private var session: (any MobileElasticsearchServing)?
    init(makeSession: @escaping @Sendable () throws -> any MobileElasticsearchServing, object: WorkspaceDatabaseObject, sort: WorkspaceDatabaseDataSort, filter: WorkspaceDatabaseDataFilter) {
        self.makeSession = makeSession; self.object = object; self.sort = sort; self.filter = filter
    }
    func page(offset: Int, limit: Int) async throws -> WorkspacePagedDataExportRowSource.Page {
        try Task.checkCancellation()
        let service: any MobileElasticsearchServing
        if let session { service = session }
        else { service = try makeSession(); session = service; try await service.connect() }
        let sink = MobileElasticsearchExportBatch()
        let result = try await service.fetchDataPage(for: object, in: "Elasticsearch", offset: offset, limit: limit, sort: sort, filter: filter) { await sink.append($0.rows) }
        try Task.checkCancellation()
        return .init(columns: result.columns, rows: await sink.rows, hasNextPage: result.hasNextPage)
    }
    func close() async { let active = session; session = nil; await active?.close() }
}
private actor MobileElasticsearchExportBatch {
    var rows: [WorkspaceDatabaseDataRow] = []
    func append(_ rows: [WorkspaceDatabaseDataRow]) { self.rows.append(contentsOf: rows) }
}

extension MobileElasticsearchWorkspace {
    var exportSnapshot: MobileDataExportSnapshot {
        var snapshot = MobileDataExportSnapshot(data: originalData, name: selected?.name ?? "es", scopeDescription: "当前已加载的服务器文档页（不含暂存修改）", sqlDialect: nil)
        guard let object = selected, let page, !isLoadingPage else { return snapshot }
        let makeSession = exportSessionFactory, sort = sort, filter = filter, expected = page.columns
        snapshot.allRowsProvider = .init(estimatedRowCount: totalCount, makeSource: {
            let session = MobileElasticsearchExportSession(makeSession: makeSession, object: object, sort: sort, filter: filter)
            return WorkspacePagedDataExportRowSource(pageSize: 500, expectedColumns: expected, loadPage: { offset, limit in
                try await session.page(offset: offset, limit: limit)
            }, onFinish: { await session.close() })
        })
        return snapshot
    }
}
