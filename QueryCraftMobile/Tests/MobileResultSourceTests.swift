import Foundation
import Testing
import QueryCraftMobileCore
import QueryCraftMobileTransport
@testable import QueryCraftMobileProof

@MainActor struct MobileResultSourceTests {
    @Test func allSurfacesReuseRawKeysAndOnePendingModel() throws {
        let fixture = SurfaceEditingFixture(), source = fixture.source
        let captured = try source.edit(row: 0, column: 1)
        try captured.validateContext()
        try captured.changes.stage(captured.request, text: "pending", mode: .value)
        #expect(source.data.cell(row: 0, column: 1) == .text("pending"))
        #expect(source.data.pendingCells == [.init(row: 0, column: 1)])
        let record = try source.edit(row: 0, column: 1)
        #expect(record.changes === captured.changes)
        #expect(record.request.initialText == "pending"); #expect(record.request.originalValue == .text("before"))
        #expect(record.request.primaryKey.first?.value == .text("318987599031067570"))
        try record.changes.stage(record.request, text: "before", mode: .value)
        #expect(!captured.changes.hasChanges); #expect(source.data.pendingCells.isEmpty)
    }
    @Test func stagingDoesNotInvalidateCaptureButRefreshDoesAndCannotWriteDifferentRow() throws {
        let fixture = SurfaceEditingFixture(), source = fixture.source
        let captured = try source.edit(row: 0, column: 1), generation = source.generation
        try fixture.changes.stage(captured.request, text: "stage", mode: .value)
        source.receive(fixture.snapshot(revision: "pending", raw: "raw"))
        #expect(source.generation == generation); try captured.validateContext()
        source.receive(fixture.snapshot(revision: "refresh", raw: "refreshed"))
        #expect(source.generation != generation)
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try captured.validateContext() }
        #expect(fixture.changes.hasChanges)
    }
    @Test func loadingAndChangedPageOrQueryIdentityRejectCapturedActions() throws {
        for context in ["page", "query", "object"] {
            let fixture = SurfaceEditingFixture(), source = fixture.source
            let captured = try source.edit(row: 0, column: 1)
            var loading = fixture.snapshot(); loading.isLoading = true
            source.receive(loading)
            #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try captured.validateContext() }
            let identity = MobileResultSourceIdentity(widthKey: context == "object" ? "other" : "table",
                timestampScope: context == "query" ? "new" : nil,
                page: context == "page" ? .init(page: fixture.page(offset: 100)) : .init(page: fixture.page()))
            let switched = fixture.snapshot(identity: identity)
            source.receive(switched)
            #expect(!source.isCurrent)
            source.receive(fixture.snapshot())
            #expect(!source.isCurrent, "A stale source must never regain ownership")
            #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try captured.validateContext() }
            #expect(!fixture.changes.hasChanges)
        }
    }
    @Test func readonlyFallbackPreservesValuesAndCommonTypeGuards() throws {
        let fixture = SurfaceEditingFixture(), source = fixture.source
        for (column, error) in [(2, WorkspaceDatabaseDataCellEditError.binaryValueUnavailable), (3, .generatedColumn)] {
            #expect(throws: error) { try source.edit(row: 0, column: column) }
            guard case .inspect(_, let reason) = source.cell(row: 0, column: column)?.content else { Issue.record("readonly inspection missing"); continue }
            #expect(reason != nil)
        }
        var readonly = fixture.snapshot(); readonly.editing = nil; readonly.page = nil; readonly.readOnlyReason = "view"
        let view = MobileResultSource(readonly)
        guard case .inspect(let cell, let reason) = view.cell(row: 0, column: 2)?.content else { Issue.record("missing binary inspection"); return }
        #expect(cell.value == .binary(byteCount: 3, preview: [0, 65, 255])); #expect(reason == "view")
        #expect(view.cell(row: -1, column: 0) == nil); #expect(view.cell(row: 0, column: 99) == nil)
    }
    @Test func queryAliasAndExpressionUseSameOriginValidationInEverySurface() async throws {
        let model = MobileQueryModel(executor: SurfaceQueryExecutor(), metadataService: QueryEditingMetadata())
        model.database = "db"; model.sql = "SELECT id AS k,name AS label,UPPER(name) AS expression FROM t"
        await model.execute()?.value
        let page = try #require(model.editingPage), changes = try #require(model.editing)
        let source = MobileResultSource(.init(data: model.displayData, revision: "query", dataRevision: "raw",
            identity: .init(widthKey: "query", timestampScope: model.resultID.uuidString, page: nil), editing: changes, page: page))
        let edit = try source.edit(row: 0, column: 1)
        #expect(edit.request.column.name == "name")
        #expect(throws: WorkspaceDatabaseDataCellEditError.metadataUnavailable) { try source.edit(row: 0, column: 2) }
        try changes.stage(edit.request, text: "query staged", mode: .value)
        #expect(source.data.cell(row: 0, column: 1) == .text("query staged"))
        model.sql = "SELECT 2"; #expect(model.execute() == nil)
        changes.discard(); await model.execute()?.value
        #expect(throws: WorkspaceDatabaseDataCellEditError.editingContextChanged) { try edit.changes.stage(edit.request, text: "stale", mode: .value) }
    }
}

@MainActor final class SurfaceEditingFixture {
    let columns: [MobileTableColumn]
    let changes: MobileTableChanges
    let object = MobileDatabaseObject(database: "db", name: "t", kind: .table, comment: "")
    lazy var source = MobileResultSource(snapshot())
    init() {
        columns = [.init(name: "id", type: "bigint", isNullable: false, key: "PRI", defaultValue: nil, extra: "", comment: "raw key"),
            .init(name: "name", type: "varchar(80)", isNullable: true, key: "", defaultValue: nil, extra: "", comment: "name comment"),
            .init(name: "binary", type: "varbinary(10)", isNullable: true, key: "", defaultValue: nil, extra: "", comment: ""),
            .init(name: "computed", type: "varchar(80)", isNullable: true, key: "", defaultValue: nil, extra: "STORED GENERATED", comment: "")]
        changes = MobileTableChanges(object: object, metadata: columns,
            configuration: .init(host: "127.0.0.1", port: 1, username: "unused", password: nil, database: "db", tlsMode: .disabled),
            safetyLock: WorkspaceSafetyLock())
    }
    func page(offset: Int = 0) -> MobileTableSnapshot {
        let result = CDatabaseQueryResult(columns: columns.map(\.name), columnTypes: columns.map(\.type),
            rows: (0..<100).map { [String(318987599031067570 + $0), $0 == 0 ? "before" : "row \($0)", "binary", "computed"] })
        let cells: [[WorkspaceDatabaseDataCell]] = result.rows.map { [.text($0[0]!), .text($0[1]!), .binary(byteCount: 3, preview: [0, 65, 255]), .text("computed")] }
        return .init(object: object, preview: .init(result: result, cells: cells), columns: columns, offset: offset, pageSize: 100,
            hasNextPage: false, hasStableOrder: true)
    }
    func snapshot(revision: String = "display", raw: String = "raw", identity: MobileResultSourceIdentity? = nil) -> MobileResultSnapshot {
        let page = page()
        return .init(data: .init(preview: page.preview, details: columns.map { $0.type + " · " + $0.comment }), revision: revision,
            dataRevision: raw, identity: identity ?? .init(widthKey: "table", timestampScope: nil, page: .init(page: page)), editing: changes, page: page)
    }
}

private struct SurfaceQueryExecutor: MobileQueryExecuting {
    func execute(configuration: MariaDBTransportConfiguration, sql: String) async throws -> CDatabaseQueryResult {
        .init(columns: ["k", "label", "expression"], columnTypes: ["int", "varchar(80)", "varchar(80)"],
            columnOrigins: [.init(databaseName: "db", tableName: "t", columnName: "id"), .init(databaseName: "db", tableName: "t", columnName: "name"), nil],
            rows: [["1", "before", "BEFORE"]])
    }
}
